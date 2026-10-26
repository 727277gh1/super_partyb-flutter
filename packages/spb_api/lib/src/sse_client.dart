import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// SSE 连接状态。
enum SseState {
  /// 未连接（初始态或已主动断开）。
  idle,

  /// 正在建立连接。
  connecting,

  /// 已连接，正常接收事件。
  connected,

  /// 连接断开，正在退避重连。
  reconnecting,

  /// 因不可恢复错误（如 401）永久停止。
  failed,
}

/// 服务端发送的原始 SSE 帧。
///
/// 解析到这一层为止——「帧 → ChatEvent」的转换放在上层，
/// 使本类可被独立测试且不依赖事件契约。
class SseFrame {
  const SseFrame({required this.event, required this.data, required this.id});

  /// `event:` 字段值。心跳帧为 null。
  final String? event;

  /// `data:` 字段值（可能由多行拼接）。
  final String data;

  /// `id:` 字段值（服务端未发则为 null）。
  final String? id;

  /// 是否为注释行（`: heartbeat`）。
  ///
  /// 服务端每 3s 发一次心跳，目的是让 CDN（EdgeOne 等）不把空闲连接判超时
  /// 返回 524。心跳**不应**进入业务事件流，但可用于刷新「连接存活」计时。
  bool get isComment => event == null && data.isEmpty;

  @override
  String toString() => 'SseFrame(event=$event, id=$id, dataLen=${data.length})';
}

/// 把增量 UTF-8 解码器接出来的字符串转交给 [onText]。
///
/// `startChunkedConversion` 要求一个 `Sink<String>`；这里用一个具名类而不是
/// 内联 lambda，因为测试要能单独构造它。
class _Utf8LineSink implements Sink<String> {
  _Utf8LineSink(this.onText);

  final void Function(String) onText;

  @override
  void add(String data) => onText(data);

  @override
  void close() {}
}

/// SSE 流式客户端。
///
/// ## 为什么手写解析而不是用现成包
///
/// 1. Go API 的 SSE 格式极简（`event:` + `data:` + 空行 + `: heartbeat` 注释），
///    规范子集小；
/// 2. 需要**精确控制重连游标**（`?cursor=<最后 eventId>`）与退避策略，现成包的
///    重连语义各不相同且难以接管；
/// 3. 需要把「HTTP 流错误」统一映射成 [SpbError]，与其余 API 调用一致。
///
/// ## 与服务端的契约（见 `internal/server/chat_stream.go`）
///
/// - 端点：`GET /users/:user_id/chat/stream?cursor=<eventId>`
/// - 格式：`event: <type>\ndata: <json>\n\n`，心跳 `: heartbeat\n\n`
/// - `cursor` 回放：返回该事件**之后**落库的事件，上限 500 条
/// - 超出回放窗口时返回空 → 客户端应改用 timeline API 整段回填
///
/// ## 使用方式
///
/// ```dart
/// final client = SseClient(dio: dio, baseUrl: env.apiBaseUrl);
/// client.frames.listen((frame) { ... });
/// await client.connect(path: '/users/$uid/chat/stream');
/// // ...
/// await client.close();
/// ```
class SseClient {
  SseClient({
    required Dio dio,
    required this.baseUrl,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.maxRetries = 10,
    this.connectTimeout = const Duration(seconds: 15),
  }) : _dio = dio;

  final Dio _dio;

  /// 当前基地址。
  ///
  /// ## 为什么**不是** `final`（issue #50）
  ///
  /// 双栈端点选择会在运行中降级/升级（`SpbEndpoints.changes`），而
  /// `baseUrl` 是构造期快照。若保持 final，降级后 SSE 会继续重连**同一个
  /// 已不可达的 host**，而「SSE 连上了」又是离线队列与看门狗的恢复信号
  /// （见 `ChatStreamController` 的 `SseState.connected` 分支）——那个信号
  /// 永远不会来，用户只能重启 App。
  ///
  /// 改基地址必须走 [switchBaseUrl]（它同时清游标与重建连接），不能直接
  /// 赋值。
  String baseUrl;

  /// 首次重连退避时长（指数增长起点）。
  final Duration initialBackoff;

  /// 退避上限。
  final Duration maxBackoff;

  /// 最大重连次数；超出后进入 [SseState.failed]。
  ///
  /// 设上限而非无限重试：移动端长时间断网时无限重试会持续耗电。
  final int maxRetries;

  final Duration connectTimeout;

  final _frameController = StreamController<SseFrame>.broadcast();
  final _stateController = StreamController<SseState>.broadcast();

  CancelToken? _cancelToken;
  StreamSubscription<List<int>>? _byteSub;
  SseState _state = SseState.idle;
  int _retryCount = 0;
  String? _path;
  String? _lastEventId;
  bool _closedByUser = false;
  Timer? _retryTimer;

  /// 解析后的 SSE 帧流。
  Stream<SseFrame> get frames => _frameController.stream;

  /// 连接状态变化流。
  Stream<SseState> get states => _stateController.stream;

  SseState get state => _state;

  /// 最后收到的事件 ID，用于断线重连的 cursor。
  String? get lastEventId => _lastEventId;

  /// 建立连接。
  ///
  /// [path] 为相对路径（如 `/users/xxx/chat/stream`），会拼接到 [baseUrl]。
  /// 重复调用会先关闭既有连接。
  Future<void> connect({required String path}) async {
    await _teardown();
    _closedByUser = false;
    _retryCount = 0;
    _path = path;
    _lastEventId = null;
    await _openStream();
  }

  /// 主动关闭，不再重连。
  Future<void> close() async {
    _closedByUser = true;
    _retryTimer?.cancel();
    await _teardown();
    _setState(SseState.idle);
  }

  /// 从上次事件续接（断线后由上层手动触发，或自动重连时内部调用）。
  ///
  /// ## 必须重置退避计数（issue #50 顺带修正）
  ///
  /// 曾经只有 [connect] 重置 `_retryCount`，`resume` 不重置。于是一旦自动
  /// 重连走到 `maxRetries` 进入 [SseState.failed]，用户点「重连」只会赌一次：
  /// 再失败一次就立即又 `failed`（`_retryCount(10) >= maxRetries`），
  /// 指数退避形同虚设。而手动重连的语义就是「从现在重新开始」——
  /// 与 [connect] 同待遇。
  Future<void> resume() async {
    if (_path == null) return;
    _closedByUser = false;
    _retryCount = 0;
    await _teardown();
    await _openStream();
  }

  /// 换基地址并重建连接（issue #50 降级/升级）。
  ///
  /// ## 为什么要清游标（不能复用 [resume]）
  ///
  /// `eventId` 是**某个服务端实例**的事件序号。降级时 host 从源站换回 CDN，
  /// 两者可能是不同的服务端实例（源站与 CDN 边缘缓存的后端），用旧 host 的
  /// 游标去新 host 请求回放，轻则跳过事件、重则拿到空页而客户端以为「已同步」。
  /// 故换 host 必须当新连接处理（`_lastEventId = null`），让上层整段回填。
  ///
  /// 返回 `false` 表示当前未处于连接状态（没有 path，或用户已主动关闭）——
  /// 此时只更新基地址，不发起连接。
  Future<bool> switchBaseUrl(String nextBaseUrl) async {
    if (nextBaseUrl == baseUrl) return false;
    baseUrl = nextBaseUrl;
    final path = _path;
    if (path == null || _closedByUser) return false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryCount = 0;
    _lastEventId = null;
    await _teardown();
    await _openStream();
    return true;
  }

  Future<void> _openStream() async {
    final path = _path;
    if (path == null) return;

    _setState(SseState.connecting);
    _cancelToken = CancelToken();

    // cursor 续接：带上最后收到的事件 ID，服务端回放其后的事件。
    final query = <String, dynamic>{};
    final cursor = _lastEventId;
    if (cursor != null && cursor.isNotEmpty) {
      query['cursor'] = cursor;
    }

    try {
      final response = await _dio.get<ResponseBody>(
        '$baseUrl$path',
        queryParameters: query.isEmpty ? null : query,
        cancelToken: _cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Accept': 'text/event-stream', 'Cache-Control': 'no-cache'},
          // SSE 是长连接，不能套用普通请求的超时。
          receiveTimeout: null,
          sendTimeout: connectTimeout,
        ),
      );

      final body = response.data;
      if (body == null) {
        throw const NetworkError('SSE 响应体为空', retryable: true);
      }

      _setState(SseState.connected);
      _retryCount = 0; // 连接成功即重置退避，避免历史失败累积影响下次断线
      SpbLog.info('SSE 已连接', {'path': path, 'cursor': cursor ?? '(none)'});

      // 每次连接重建增量解码器：新连接不得携带上一个连接的不完整字节。
      final sink = _Utf8LineSink(_onText);
      _utf8Sink = const Utf8Decoder(allowMalformed: true)
          .startChunkedConversion(sink);

      _byteSub = body.stream.listen(
        (bytes) => _utf8Sink?.add(bytes),
        onError: (Object e, StackTrace st) {
          SpbLog.warn('SSE 流错误', {'error': e.toString()});
          _scheduleReconnect();
        },
        onDone: () {
          SpbLog.info('SSE 流结束');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } on DioException catch (e) {
      final mapped = mapDioError(e);
      // 401/403 属不可恢复：重连只会重复被拒，直接置 failed 让上层跳登录。
      // 用 [AuthError] 判定（不是 `HttpError.isUnauthorized`）：认证失败在
      // `mapDioError` 里已统一归为 AuthError，见 `auth_interceptor.dart`。
      if (mapped is AuthError &&
          (mapped.isUnauthorized || mapped.isForbidden)) {
        SpbLog.warn('SSE 认证失败，停止重连', {'status': mapped.statusCode});
        _setState(SseState.failed);
        _frameController.addError(mapped);
        return;
      }
      SpbLog.warn('SSE 连接失败', {'error': mapped.toString()});
      _scheduleReconnect(error: mapped);
    } catch (e, st) {
      SpbLog.error('SSE 连接异常', error: e, stackTrace: st);
      _scheduleReconnect(error: NetworkError(e.toString(), cause: e));
    }
  }

  /// SSE 按行分隔，但网络分片不保证与行边界对齐——必须缓冲到完整行。
  ///
  /// ## 为什么用**增量** UTF-8 解码器，而不是对每个分片单独 `utf8.decode`
  ///
  /// 曾经的写法是对每个分片独立 `utf8.decode(bytes, allowMalformed: true)`，
  /// 注释写「容忍分片切开的 UTF-8 多字节序列」——但 `allowMalformed` 的语义是
  /// 「解不出就替换成 U+FFFD」，**不是**「缓冲到下一个分片」。当分片边界落在
  /// 汉字 3 字节序列的中间时，两个分片各自解出替换字符，且**不可恢复**：
  /// 「中文」会变成「���文」。
  ///
  /// 实测（issue #41 补测试时发现）：
  ///
  /// ```
  /// final bytes = utf8.encode('data: {"t":"中文"}\n\n');
  /// // 在「中」的首字节后切分
  /// utf8.decode(bytes.sublist(0, cut), allowMalformed: true) // → 'data: {"t":"�'
  /// utf8.decode(bytes.sublist(cut), allowMalformed: true)    // → '��文"}\n\n'
  /// ```
  ///
  /// 后果是中文回复在网络分片恰好落在汉字中间时显示成乱码，且**只在分片边界**
  /// 出现——本机跑（通常一个分片装下整个响应）永远复现不了。
  ///
  /// `Utf8Decoder.startChunkedConversion` 会跨分片保留不完整序列（实测切分后
  /// 拼接结果与整段解码逐字节相同），故改用它。
  ///
  /// 这也是不用 `transform(utf8.decoder).transform(LineSplitter())` 的原因：
  /// 那样虽然能切行，但会丢掉「跨帧边界的事件」所需的空行语义与注释行识别。
  /// 跨分片携带的**不完整行**（无 `\n` 结尾的那一段）。
  ///
  /// 只在末尾写入一次（一次切片），不是每行都重切——见 [_onText] 的复杂度说明。
  String _lineBuf = '';
  final _pendingData = StringBuffer();
  String? _pendingEvent;
  String? _pendingId;

  /// 当前连接的增量解码 sink；每次 `_openStream` 重建（新连接不得携带旧连接
  /// 的不完整字节）。
  ByteConversionSink? _utf8Sink;

  /// 接收解码后的文本，按行切分。
  ///
  /// ## 为什么用偏移游标而不是反复 `substring`
  ///
  /// 曾经的写法是 `content = content.substring(idx + 1)` 每处理一行就重切一次
  /// 剩余串。那是一个含 k 行的分片会产生 **O(k·L)** 的字符拷贝（每行都把
  /// 剩下的大半串再拷一遍）。而 SSE 的一次网络分片里出现几十上百行是常态
  /// （回放窗口一次回 500 条时更明显），于是这层成了「推流时越跑越慢」的
  /// 隐性成本。
  ///
  /// 现在只用一个 `start` 游标往后走：
  ///
  /// - 每行 `content.substring(start, idx)`——每行一次、长度等于该行；
  /// - 循环结束后 `content.substring(start)`——**一次**切出剩余半行。
  ///
  /// 于是单个分片的拷贝总量与分片长度成**线性**（与行数无关）。
  ///
  /// ⚠️ 代价是一个无法避免的拷贝：Dart 的 `String` 不可变，所以「上次的半行 +
  /// 本次分片」必然要拼一次。但那是**每分片一次**，不是每行一次。
  void _onText(String text) {
    // 常见路径（半行恰好为空）不拼，直接看本次分片。
    final content = _lineBuf.isEmpty ? text : _lineBuf + text;

    var start = 0;
    var idx = content.indexOf('\n');
    while (idx >= 0) {
      var line = content.substring(start, idx);
      // 兼容 CRLF（HTTP 中间件可能改写行尾）。
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      _handleLine(line);
      start = idx + 1;
      // 必须带 `start` 作起点：不带的话每次都从 0 找，退化回 O(k·L)。
      idx = content.indexOf('\n', start);
    }

    // 剩余不完整行留到下次分片（`start == 0` 说明整段都没换行，原样留下，
    // 连这一次切片也省了）。
    _lineBuf = start == 0 ? content : content.substring(start);
  }

  void _handleLine(String line) {
    // 空行 = 帧结束。
    if (line.isEmpty) {
      _emitFrame();
      return;
    }
    // 注释行（`: heartbeat`）——服务端 3s 一次的心跳。
    // 直接推送注释帧（不经过 _emitFrame 的 data 累积逻辑，注释不携带 data）。
    if (line.startsWith(':')) {
      _pushFrame(const SseFrame(event: null, data: '', id: null));
      return;
    }

    final colon = line.indexOf(':');
    if (colon < 0) {
      // 无冒号的行按规范视为「字段名 + 空值」，本项目用不到，忽略。
      return;
    }

    final field = line.substring(0, colon);
    // 规范：冒号后的**单个**空格要跳过，其余空格属于值。
    var value = line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'event':
        _pendingEvent = value;
      case 'data':
        // 多行 data 用 \n 拼接（规范要求）。
        if (_pendingData.isNotEmpty) _pendingData.write('\n');
        _pendingData.write(value);
      case 'id':
        _pendingId = value;
      case 'retry':
        // 服务端未使用；保留解析以便将来接管退避时长。
        break;
    }
  }

  void _emitFrame() {
    final hasContent = _pendingData.isNotEmpty || _pendingEvent != null;
    if (!hasContent) return;

    final data = _pendingData.toString();
    final frame = SseFrame(
      event: _pendingEvent,
      data: data,
      id: _pendingId ?? _lastEventId,
    );
    _pendingData.clear();
    _pendingEvent = null;

    _pushFrame(frame);
  }

  /// 直接推送一个帧（不做 data 累积/清理），供心跳注释帧使用。
  void _pushFrame(SseFrame frame) {
    if (!_frameController.isClosed) _frameController.add(frame);
  }

  /// 记录事件 ID，供断线重连使用。
  ///
  /// 由上层在成功解析出 [ChatEvent] 后调用——**只有落库事件才有有效 ID**，
  /// Transient 事件（流式增量）的 ID 不能作为 cursor，否则重连会跳过它们
  /// 之后落库的权威帧。
  void recordEventId(String eventId) {
    if (eventId.isEmpty) return;
    _lastEventId = eventId;
  }

  void _scheduleReconnect({SpbError? error}) {
    if (_closedByUser) return;

    if (_retryCount >= maxRetries) {
      SpbLog.error('SSE 重连次数超限，放弃', fields: {'retries': _retryCount});
      _setState(SseState.failed);
      if (error != null && !_frameController.isClosed) {
        _frameController.addError(error);
      }
      return;
    }

    _retryCount++;
    // 指数退避：1s, 2s, 4s, ... 封顶 maxBackoff。
    final backoffMs = initialBackoff.inMilliseconds * (1 << (_retryCount - 1));
    final backoff = Duration(
      milliseconds: backoffMs > maxBackoff.inMilliseconds
          ? maxBackoff.inMilliseconds
          : backoffMs,
    );

    _setState(SseState.reconnecting);
    SpbLog.info('SSE 将在退避后重连', {
      'attempt': _retryCount,
      'backoffMs': backoff.inMilliseconds,
    });

    _retryTimer?.cancel();
    _retryTimer = Timer(backoff, () {
      if (!_closedByUser) _openStream();
    });
  }

  void _setState(SseState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  Future<void> _teardown() async {
    await _byteSub?.cancel();
    _byteSub = null;
    _utf8Sink = null;
    if (_cancelToken != null && !_cancelToken!.isCancelled) {
      _cancelToken!.cancel('SSE 连接重建');
    }
    _cancelToken = null;
    // 新连接不得携带上一个连接的不完整行（否则两段无关字节会被拼成一行）。
    _lineBuf = '';
    _pendingData.clear();
    _pendingEvent = null;
    _pendingId = null;
  }

  /// 释放资源。调用后实例不可再用。
  Future<void> dispose() async {
    _closedByUser = true;
    _retryTimer?.cancel();
    await _teardown();
    await _frameController.close();
    await _stateController.close();
  }
}

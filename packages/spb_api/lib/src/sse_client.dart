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
  final String baseUrl;

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
  Future<void> resume() async {
    if (_path == null) return;
    _closedByUser = false;
    await _teardown();
    await _openStream();
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

      _byteSub = body.stream.listen(
        _onBytes,
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
      if (mapped is HttpError &&
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
  /// 这也是不用 `transform(utf8.decoder).transform(LineSplitter())` 的原因：
  /// 那样虽然能切行，但会丢掉「跨帧边界的事件」所需的空行语义与注释行识别，
  /// 且难以处理不完整 UTF-8 序列（中文被切在两个分片之间）。
  final _lineBuffer = StringBuffer();
  final _pendingData = StringBuffer();
  String? _pendingEvent;
  String? _pendingId;

  void _onBytes(List<int> bytes) {
    // 用 allowMalformed 容忍分片切开的 UTF-8 多字节序列：
    // 中文回复被网络分片切断时，严格解码会抛 FormatException 直接断流。
    final text = utf8.decode(bytes, allowMalformed: true);
    _lineBuffer.write(text);

    var content = _lineBuffer.toString();
    var idx = content.indexOf('\n');
    while (idx >= 0) {
      var line = content.substring(0, idx);
      // 兼容 CRLF（HTTP 中间件可能改写行尾）。
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      _handleLine(line);
      content = content.substring(idx + 1);
      idx = content.indexOf('\n');
    }

    // 剩余不完整行留到下次分片。
    _lineBuffer
      ..clear()
      ..write(content);
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
    if (_cancelToken != null && !_cancelToken!.isCancelled) {
      _cancelToken!.cancel('SSE 连接重建');
    }
    _cancelToken = null;
    _lineBuffer.clear();
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

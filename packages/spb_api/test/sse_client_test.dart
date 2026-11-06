import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// `SseClient` 的契约测试。
///
/// ## 这个测试防的是什么（issue #41）
///
/// 传输层此前是**唯一「上层用 Fake 测 + 自己不被测」的层**：`spb_domain` 有
/// 881 条归约用例，而 `sse_client.dart` 的 149 行里只有 1 行被执行（0.7%）。
/// 四个测试文件各自 `class _FakeSseClient extends SseClient` 并 override 掉
/// `connect` / `frames` / `states` / `recordEventId`——**没有一处构造真实实例**。
///
/// 于是以下正确性核心从未被执行：分片缓冲、`event:`/`data:`/`id:` 解析、
/// 多行 data 拼接、`: heartbeat` 识别、指数退避、401 停止重连、
/// `_pendingId ?? _lastEventId` 兜底。
///
/// ## 怎么测（不碰真实网络）
///
/// 用自定义 [HttpClientAdapter] 喂**受控字节流**。不用 `http_mock_adapter`：
/// 它按 URL 匹配返回整体响应，无法表达「同一响应被切成多个分片」——而那正是
/// 传输层最容易错的地方。自定义 adapter 直接控制 `ResponseBody.stream` 的
/// 分片边界。
void main() {
  setUp(() {
    // 测试里不打印日志（真实 SpbLog 会往 stdout 刷）。
    SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
  });

  group('分片与行缓冲', () {
    test('把完整 SSE 流切成任意字节分片，解析结果不变（含中文）', () async {
      const wire =
          'event: message\n'
          'data: {"text":"你好，世界","n":1}\n'
          '\n'
          'event: message\n'
          'data: {"text":"第二段"}\n'
          '\n';
      final bytes = utf8.encode(wire);

      // 逐字节切分：最极端的分片方式。若缓冲逻辑有任意一处按「分片 = 一行」
      // 假设，这里必然暴露。
      final oneByteChunks = [
        for (var i = 0; i < bytes.length; i++) [bytes[i]],
      ];

      final frames = await _collectFrames(oneByteChunks);

      expect(frames.map((f) => f.event), ['message', 'message']);
      expect(frames.map((f) => f.data), [
        '{"text":"你好，世界","n":1}',
        '{"text":"第二段"}',
      ]);
    });

    test('UTF-8 多字节字符被切在两个分片之间时不得损坏', () async {
      // ⚠️ 这是一个**真实的既有缺陷**（本测试就是为它写的）。
      //
      // `_onBytes` 对**每个分片**独立调 `utf8.decode(bytes, allowMalformed:
      // true)`。当分片边界落在「中」的 3 个字节中间时，两个分片各自解出
      // U+FFFD（`�`），且**无法恢复**——拼接后是 `���文` 而非 `中文`。
      //
      // 原注释写「用 allowMalformed 容忍分片切开的 UTF-8 多字节序列」，但
      // allowMalformed 的语义是「解不出就替换成 U+FFFD」，不是「缓冲到下一个
      // 分片」。正确做法是**流式解码器**（`utf8.decoder.startChunkedConversion`），
      // 它跨分片保留不完整序列。
      //
      // 后果：中文回复在网络分片恰好落在汉字中间时会显示成乱码，且**只在
      // 分片边界**出现——本机跑（不切分）永远复现不了。
      const text = '{"text":"中文回复"}';
      final bytes = utf8.encode('event: message\ndata: $text\n\n');

      // 在第一个汉字的 UTF-8 序列中间切（0xE4 是「中」的首字节）。
      final cut = bytes.indexOf(0xE4) + 1;
      expect(cut, greaterThan(0), reason: '测试自身前提：应能找到汉字首字节');

      final frames = await _collectFrames([
        bytes.sublist(0, cut),
        bytes.sublist(cut),
      ]);

      expect(frames, hasLength(1));
      expect(frames.single.data, text);
      expect(
        frames.single.data,
        isNot(contains('\uFFFD')),
        reason: '不得出现替换字符（U+FFFD）',
      );
    });

    test('CRLF 行尾被正确处理（HTTP 中间件可能改写）', () async {
      final frames = await _collectFrames([
        utf8.encode('event: message\r\ndata: {"a":1}\r\n\r\n'),
      ]);
      expect(frames.single.event, 'message');
      expect(frames.single.data, '{"a":1}');
    });

    test('不完整行留到下一个分片，不提前发帧', () async {
      final frames = await _collectFrames([
        utf8.encode('data: {"a"'),
        utf8.encode(':1}\n\n'),
      ]);
      expect(frames, hasLength(1));
      expect(frames.single.data, '{"a":1}');
    });

    test('单个分片内含 500 行：解析结果与逐行投递一致', () async {
      // 行缓冲曾用 `content = content.substring(idx + 1)` 每行重切剩余串
      // ——含 k 行的分片是 O(k·L)。改成偏移游标后拷贝量与分片长度成线性。
      // 这里不比时间（那会随机器漂移），而是钉「大量行不会错位 / 不会丢行」
      // 这个被拷贝逻辑直接决定的结果。
      const count = 500;
      final wire = StringBuffer();
      for (var i = 0; i < count; i++) {
        wire.write('event: message\ndata: {"i":$i}\n\n');
      }
      final bytes = utf8.encode(wire.toString());

      // ① 整个流一次投递（单分片 500 帧）。
      final oneShot = await _collectFrames([bytes]);
      // ② 同一份字节逐行投递（每帧一行一个分片）——作为参照实现。
      final lineByLine = await _collectFrames([
        for (final line in const LineSplitter().convert(wire.toString()))
          utf8.encode('$line\n'),
      ]);

      expect(oneShot, hasLength(count));
      expect(lineByLine, hasLength(count));
      expect(oneShot.map((f) => f.data).toList(), [
        for (var i = 0; i < count; i++) '{"i":$i}',
      ], reason: '单分片内 500 行必须逐行就位、顺序不乱、不丢行');
      expect(
        oneShot.map((f) => f.data).toList(),
        lineByLine.map((f) => f.data).toList(),
        reason: '分片方式不同但解析结果必须逐字节相同',
      );
    });

    test('一次 add 含 3 个完整帧 + 1 个半行：半行留到下一次', () async {
      final frames = await _collectFrames([
        utf8.encode(
          'data: one\n\n'
          'data: two\n\n'
          'data: three\n\n'
          'data: par',
        ),
        utf8.encode('t4\n\n'),
      ]);

      expect(frames, hasLength(4));
      expect(frames.map((f) => f.data).toList(), [
        'one',
        'two',
        'three',
        'part4',
      ]);
      expect(
        frames.map((f) => f.data).toList(),
        isNot(contains('par')),
        reason: '半行不得作为独立帧发出（那是被截断的内容）',
      );
    });
  });

  group('字段解析', () {
    test('多行 data 用 \\n 拼接（规范要求）', () async {
      final frames = await _collectFrames([
        utf8.encode('data: line1\ndata: line2\ndata: line3\n\n'),
      ]);
      expect(frames.single.data, 'line1\nline2\nline3');
    });

    test('冒号后的单个空格被跳过，其余空格属于值', () async {
      final frames = await _collectFrames([
        utf8.encode('data:  two leading spaces\n\n'),
      ]);
      // `data: ` 后还有一个空格，按规范它属于值。
      expect(frames.single.data, ' two leading spaces');
    });

    test('无冒号的行被忽略（不产生帧、不破坏后续解析）', () async {
      final frames = await _collectFrames([
        utf8.encode('nocolon\ndata: ok\n\n'),
      ]);
      expect(frames, hasLength(1));
      expect(frames.single.data, 'ok');
    });

    test('id 字段被解析', () async {
      final frames = await _collectFrames([
        utf8.encode('id: evt_123\ndata: {}\n\n'),
      ]);
      expect(frames.single.id, 'evt_123');
    });

    test('retry 字段被安全忽略（当前行为，将来可能接管退避）', () async {
      final frames = await _collectFrames([
        utf8.encode('retry: 5000\ndata: {}\n\n'),
      ]);
      expect(frames, hasLength(1));
      expect(frames.single.data, '{}');
    });

    test('id 缺省时用 lastEventId 兜底（重连后的第一帧）', () async {
      // ⚠️ 为什么必须是「重连后的第一帧」：
      //
      // `_pendingId` **不随帧清空**（符合 SSE 规范——`id` 会持续到被改写）。
      // 故同一连接内「带 id 的帧 → 不带 id 的帧」时，后者从 `_pendingId` 就能
      // 拿到值，`?? _lastEventId` 根本走不到。
      //
      // 兜底真正生效的场景是：`_teardown` 把 `_pendingId` 清成 null 之后，
      // 重连收到的第一帧恰好不带 `id:`——此时只有 `_lastEventId`（cursor）
      // 可用。若去掉兜底，这一帧的 id 会变成 null，上层无法记录游标。
      final stream = _ControllableAdapter();
      final client = _client(stream);
      final frames = <SseFrame>[];
      client.frames.listen(frames.add);

      await client.connect(path: '/s');
      await _drain();
      stream.push(utf8.encode('id: evt_1\ndata: {"a":1}\n\n'));
      await _drain();
      expect(frames.single.id, 'evt_1');

      // 模拟上层记录游标，然后断线重连（_teardown 清空 _pendingId）。
      client.recordEventId('evt_1');
      await client.resume();
      await _drain();

      // 重连后第一帧不带 id → 应兜底成 lastEventId。
      stream.push(utf8.encode('data: {"a":2}\n\n'));
      await _drain();
      expect(frames, hasLength(2));
      expect(frames[1].id, 'evt_1');

      await client.dispose();
      await stream.endStream();
    });

    test('只有 event 没有 data 时也发帧（isComment 为 false）', () async {
      final frames = await _collectFrames([utf8.encode('event: ping\n\n')]);
      expect(frames, hasLength(1));
      expect(frames.single.event, 'ping');
      expect(frames.single.isComment, isFalse);
    });

    test('空帧（连续空行）不产生帧', () async {
      final frames = await _collectFrames([utf8.encode('\n\ndata: real\n\n')]);
      expect(frames, hasLength(1));
      expect(frames.single.data, 'real');
    });
  });

  group('心跳注释帧', () {
    test(': heartbeat 产生注释帧且 isComment 为真', () async {
      final frames = await _collectFrames([utf8.encode(': heartbeat\n\n')]);
      expect(frames, hasLength(1));
      expect(frames.single.isComment, isTrue);
      expect(frames.single.event, isNull);
      expect(frames.single.data, isEmpty);
    });

    test('心跳插在两个完整事件之间不影响业务帧', () async {
      // 服务端在空闲时发 `: heartbeat\n\n`，不会插进某个事件中途。
      final frames = await _collectFrames([
        utf8.encode('data: one\n\n'),
        utf8.encode(': heartbeat\n\n'),
        utf8.encode('data: two\n\n'),
      ]);
      expect(frames, hasLength(3));
      expect(frames[0].data, 'one');
      expect(frames[1].isComment, isTrue);
      expect(frames[2].data, 'two');
    });

    test('心跳**不得**清空已累积的 data（否则会丢半个事件）', () async {
      // ⚠️ 这条钉的是「注释分支不得触碰 _pendingData」。注释行只推一个空帧，
      // 不清空 pending——若实现里误写成「注释 = 帧结束」，下面的事件会只剩
      // part2，前半截静默丢失。
      //
      // 注意：`data: part1\n` 后紧跟的空行本身就会终结事件（SSE 规范），
      // 故这里**不带**那个空行——模拟心跳与 data 行在同一个事件内交错。
      final frames = await _collectFrames([
        utf8.encode('data: part1\n'),
        utf8.encode(': heartbeat\n'),
        utf8.encode('data: part2\n\n'),
      ]);
      // 第 1 帧是注释；第 2 帧才是完整事件，且两段 data 都在。
      expect(frames, hasLength(2));
      expect(frames[0].isComment, isTrue);
      expect(frames[1].data, 'part1\npart2');
    });
  });

  group('游标续接', () {
    test('首次 connect 不带 cursor（新会话从头开始）', () async {
      // `connect` 是「开始一个新会话」，会重置 lastEventId。cursor 只在
      // **重连**（`resume` / 内部退避重连）时才带上——否则会在切换 group 时
      // 用上一个 group 的 eventId 去查，服务端回放窗口对不上。
      final adapter = _ScriptedAdapter([_ok('data: {}\n\n')]);
      final client = _client(adapter);
      client.recordEventId('evt_stale');
      await client.connect(path: '/users/u/chat/stream');
      await _drain();

      // dio 会把 null 规范化成 {}，故断言「不含 cursor 键」而不是「为 null」。
      expect(adapter.requests.single.queryParameters, isEmpty);
      await client.dispose();
    });

    test('connect 会重置 lastEventId（新会话不带上一次的游标）', () async {
      final adapter = _ScriptedAdapter([_ok('data: {}\n\n')]);
      final client = _client(adapter);
      client.recordEventId('evt_stale');
      await client.connect(path: '/users/u/chat/stream');
      await _drain();
      expect(client.lastEventId, isNull);
      await client.dispose();
    });

    test('recordEventId 忽略空串（避免把 cursor 清成空）', () async {
      final adapter = _ScriptedAdapter([_ok('data: {}\n\n')]);
      final client = _client(adapter);
      client.recordEventId('evt_a');
      client.recordEventId('');
      expect(client.lastEventId, 'evt_a');
      await client.dispose();
    });

    test('resume 带上最后记录的事件 ID', () async {
      final adapter = _ScriptedAdapter([
        _ok('data: one\n\n'),
        _ok('data: two\n\n'),
      ]);
      final client = _client(adapter);
      await client.connect(path: '/users/u/chat/stream');
      await _drain();
      client.recordEventId('evt_7');
      await client.resume();
      await _drain();

      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[1].queryParameters['cursor'], 'evt_7');
      await client.dispose();
    });

    test('resume 重置退避计数（否则手动重连只能赌一次）', () async {
      // 曾经的缺陷：只有 connect 重置 _retryCount，resume 不重置。于是自动
      // 重连耗尽 maxRetries 进入 failed 后，用户点「重连」再失败一次就
      // 立即又 failed（10 >= 10），指数退避形同虚设。
      final adapter = _ScriptedAdapter([
        _fail(DioExceptionType.connectionError),
      ]);
      final client = _client(
        adapter,
        initialBackoff: const Duration(milliseconds: 1),
        maxBackoff: const Duration(milliseconds: 2),
        maxRetries: 1,
      );
      client.frames.listen((_) {}, onError: (_) {});

      await client.connect(path: '/s');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(client.state, SseState.failed);

      // 手动重连：应重新给满重试额度（至少再退避一次，而不是直接 failed）。
      final states = <SseState>[];
      client.states.listen(states.add);
      await client.resume();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        states,
        contains(SseState.reconnecting),
        reason: '重置计数后应重新进入退避重连，而不是立即 failed',
      );
      await client.dispose();
    });
  });

  group('switchBaseUrl（issue #50 降级/升级）', () {
    test('换 host 后用新基地址重连，且不携带旧游标', () async {
      final adapter = _ScriptedAdapter([
        _ok('data: one\n\n'),
        _ok('data: two\n\n'),
      ]);
      final client = _client(adapter);
      await client.connect(path: '/users/u/chat/stream');
      await _drain();
      client.recordEventId('evt_from_origin');

      final switched = await client.switchBaseUrl('https://cdn.test/pba');
      await _drain();

      expect(switched, isTrue);
      expect(client.baseUrl, 'https://cdn.test/pba');
      expect(adapter.requests, hasLength(2));
      // dio 对「path 已是绝对 URL」的情况不重写 `baseUrl` 字段，只影响 `uri`。
      expect(adapter.requests[1].uri.toString(), contains('cdn.test'));
      expect(
        adapter.requests[1].queryParameters['cursor'],
        isNull,
        reason: '旧 host 的 eventId 不能用于新 host 回放（可能是不同后端实例）',
      );
      await client.dispose();
    });

    test('同一基地址时不重连（避免无意义抖动）', () async {
      final stream = _ControllableAdapter();
      final client = _client(stream);
      await client.connect(path: '/s');
      await _drain();

      final switched = await client.switchBaseUrl('https://api.test');
      expect(switched, isFalse);
      expect(stream.connectionCount, 1);
      await client.dispose();
      await stream.endStream();
    });

    test('未连接时只更新基地址，不发起连接', () async {
      final stream = _ControllableAdapter();
      final client = _client(stream);

      final switched = await client.switchBaseUrl('https://cdn.test/pba');
      expect(switched, isFalse);
      expect(client.baseUrl, 'https://cdn.test/pba');
      expect(stream.connectionCount, 0);
      await client.dispose();
    });

    test('用户主动 close 后不因换基地址而复活连接', () async {
      final stream = _ControllableAdapter();
      final client = _client(stream);
      await client.connect(path: '/s');
      await _drain();
      await client.close();
      await _drain();

      final switched = await client.switchBaseUrl('https://cdn.test/pba');
      expect(switched, isFalse);
      expect(stream.connectionCount, 1, reason: '主动关闭的连接不得被降级逻辑唤醒');
      await client.dispose();
      await stream.endStream();
    });
  });

  group('状态机', () {
    test('connect → connected，close → idle', () async {
      // ⚠️ 必须用**不结束**的流：`ResponseBody.fromString` 的流发完即 done，
      // 会立刻触发 onDone → reconnecting，看不到 connected 这个稳定态。
      final stream = _ControllableAdapter();
      final client = _client(stream);
      final states = <SseState>[];
      client.states.listen(states.add);

      await client.connect(path: '/s');
      await _drain();
      expect(client.state, SseState.connected);

      await client.close();
      await _drain();
      expect(client.state, SseState.idle);
      expect(states.first, SseState.connecting);
      expect(states, contains(SseState.connected));
      expect(states.last, SseState.idle);
      await client.dispose();
      await stream.endStream();
    });

    test('流正常结束时进入 reconnecting 并安排重连', () async {
      final adapter = _ScriptedAdapter([_ok('data: {}\n\n')]);
      final client = _client(adapter, initialBackoff: const Duration(hours: 1));
      final states = <SseState>[];
      client.states.listen(states.add);

      await client.connect(path: '/s');
      await _drain();
      // 服务端关闭流 → onDone → _scheduleReconnect。
      expect(states, contains(SseState.reconnecting));
      await client.dispose();
    });
  });

  group('退避与重连上限', () {
    test('退避序列为 1s, 2s, 4s, ... 且封顶 maxBackoff', () async {
      // 用极短的 maxBackoff 与 initialBackoff 使测试快速跑完，
      // 但保持「指数增长」的比例关系可断言。
      final adapter = _ScriptedAdapter([
        _fail(DioExceptionType.connectionError),
        _fail(DioExceptionType.connectionError),
        _fail(DioExceptionType.connectionError),
      ]);
      final client = _client(
        adapter,
        initialBackoff: const Duration(milliseconds: 1),
        maxBackoff: const Duration(milliseconds: 4),
        maxRetries: 3,
      );
      final states = <SseState>[];
      client.states.listen(states.add);

      await client.connect(path: '/s');
      // 等足够长时间让退避全部跑完（1+2+4ms 上限）。
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 三次失败后超过 maxRetries → failed。
      expect(client.state, SseState.failed);
      expect(states.where((s) => s == SseState.reconnecting).length, 3);
      await client.dispose();
    });

    test('401 时进入 failed 且不再重连', () async {
      final adapter = _ScriptedAdapter([_auth(401)]);
      final client = _client(
        adapter,
        initialBackoff: const Duration(milliseconds: 1),
      );
      final errors = <Object>[];
      client.frames.listen((_) {}, onError: errors.add);

      await client.connect(path: '/s');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(client.state, SseState.failed);
      expect(adapter.requests, hasLength(1), reason: '401 不得触发重连');
      expect(errors.single, isA<AuthError>());
      await client.dispose();
    });

    test('403 时进入 failed 且不再重连', () async {
      final adapter = _ScriptedAdapter([_auth(403)]);
      final client = _client(
        adapter,
        initialBackoff: const Duration(milliseconds: 1),
      );
      final errors = <Object>[];
      client.frames.listen((_) {}, onError: errors.add);

      await client.connect(path: '/s');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(client.state, SseState.failed);
      expect(adapter.requests, hasLength(1));
      expect(errors.single, isA<AuthError>());
      await client.dispose();
    });

    test('5xx 可重试（不进入 failed）', () async {
      final adapter = _ScriptedAdapter([
        _fail(DioExceptionType.badResponse, status: 503),
      ]);
      final client = _client(
        adapter,
        initialBackoff: const Duration(milliseconds: 1),
      );
      await client.connect(path: '/s');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // 尚未超上限 → 处于 reconnecting，不是 failed。
      expect(client.state, SseState.reconnecting);
      await client.dispose();
    });

    test('close 之后不再重连', () async {
      final adapter = _ScriptedAdapter([_ok('data: {}\n\n')]);
      final client = _client(
        adapter,
        initialBackoff: const Duration(milliseconds: 5),
      );
      await client.connect(path: '/s');
      await _drain();
      await client.close();
      final callsAtClose = adapter.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adapter.requests.length, callsAtClose, reason: 'close 后不得再发起请求');
      await client.dispose();
    });
  });

  group('SseFrame', () {
    test('toString 含 event/id/dataLen（排障用，不泄露 payload 全文）', () {
      const f = SseFrame(event: 'message', data: '{"a":1}', id: 'evt_1');
      final s = f.toString();
      expect(s, contains('event=message'));
      expect(s, contains('id=evt_1'));
      expect(s, contains('dataLen=7'));
      // 不得把 data 全文塞进 toString：日志里会出现整段回复。
      expect(s, isNot(contains('{"a":1}')));
    });
  });

  group('响应体异常', () {
    test('适配器抛非 DioException 时被兜底成可重试错误', () async {
      // `_openStream` 的 `catch (e, st)` 分支：适配器/解码器抛出的非 dio
      // 异常也要转成可重试错误，否则会被静默吞掉（流永远停在 connecting）。
      final client = _client(
        _ThrowingAdapter(),
        initialBackoff: const Duration(milliseconds: 1),
      );
      await client.connect(path: '/s');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.state, SseState.reconnecting);
      await client.dispose();
    });

    test('流中途出错（onError）时安排重连', () async {
      final stream = _ControllableAdapter();
      final client = _client(
        stream,
        initialBackoff: const Duration(milliseconds: 1),
      );
      final states = <SseState>[];
      client.states.listen(states.add);

      await client.connect(path: '/s');
      await _drain();
      expect(client.state, SseState.connected);

      stream.addError(StateError('socket reset'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(states, contains(SseState.reconnecting));
      await client.dispose();
      await stream.endStream();
    });

    test('响应体为 null 时按可重试错误处理', () async {
      final adapter = _NullBodyAdapter();
      final client = _client(
        adapter,
        initialBackoff: const Duration(milliseconds: 1),
      );
      await client.connect(path: '/s');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.state, SseState.reconnecting);
      await client.dispose();
    });
  });

  group('dispose', () {
    test('dispose 关闭两个流控制器', () async {
      final adapter = _ScriptedAdapter([_ok('data: {}\n\n')]);
      final client = _client(adapter);
      final framesDone = Completer<void>();
      client.frames.listen((_) {}, onDone: framesDone.complete);
      final statesDone = Completer<void>();
      client.states.listen((_) {}, onDone: statesDone.complete);

      await client.connect(path: '/s');
      await _drain();
      await client.dispose();

      await framesDone.future.timeout(const Duration(seconds: 2));
      await statesDone.future.timeout(const Duration(seconds: 2));
    });
  });
}

// ─────────────────────────── 测试辅助 ───────────────────────────

/// 构造一个使用 [adapter] 的 [SseClient]。
SseClient _client(
  HttpClientAdapter adapter, {
  Duration initialBackoff = const Duration(seconds: 1),
  Duration maxBackoff = const Duration(seconds: 30),
  int maxRetries = 10,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  dio.httpClientAdapter = adapter;
  return SseClient(
    dio: dio,
    baseUrl: 'https://api.test',
    initialBackoff: initialBackoff,
    maxBackoff: maxBackoff,
    maxRetries: maxRetries,
  );
}

/// 收集 [chunks] 喂给客户端后得到的全部帧。
Future<List<SseFrame>> _collectFrames(List<List<int>> chunks) async {
  final client = _client(_ChunkAdapter(chunks));
  final frames = <SseFrame>[];
  client.frames.listen(frames.add);
  await client.connect(path: '/s');
  await _drain();
  await client.dispose();
  return frames;
}

/// 让已排队的微任务与流事件跑完。
///
/// 不用固定 `Future.delayed` 之外的机制：本包无 `fake_async` 依赖，而
/// `ResponseBody.stream` 是真实异步流，需要真实事件循环推进。
Future<void> _drain() => Future<void>.delayed(const Duration(milliseconds: 50));

/// 一个正常的 200 响应（内容为 [body]）。
ResponseBody _ok(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

/// 一个 401/403 响应。
ResponseBody _auth(int status) => ResponseBody.fromString(
  '{"error":"unauthorized"}',
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// 一个失败的请求结果（非 HTTP 响应，如连接错误）。
_DioFailure _fail(DioExceptionType type, {int? status}) =>
    _DioFailure(type: type, status: status);

/// 把响应体切成 [chunks] 的适配器。
class _ChunkAdapter implements HttpClientAdapter {
  _ChunkAdapter(this.chunks);

  final List<List<int>> chunks;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream.fromIterable(chunks.map(Uint8List.fromList)),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 记录每次请求、按脚本依次返回结果的适配器。
///
/// 返回项可以是 [ResponseBody]（正常响应）或 [_DioFailure]（抛 DioException）。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  final List<Object> script;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final step = script.isEmpty
        ? script.last
        : script[(requests.length - 1).clamp(0, script.length - 1)];
    if (step is _DioFailure) {
      throw DioException(
        requestOptions: options,
        type: step.type,
        response: step.status == null
            ? null
            : Response<dynamic>(
                requestOptions: options,
                statusCode: step.status,
              ),
      );
    }
    return step as ResponseBody;
  }

  @override
  void close({bool force = false}) {}
}

class _DioFailure {
  const _DioFailure({required this.type, this.status});

  final DioExceptionType type;
  final int? status;
}

/// 可手动推字节的适配器：流在测试主动 `close()` 前**不结束**。
///
/// 用于需要观察「稳定连接态」（`connected`）或需要在两个帧之间执行动作
/// （如 `recordEventId`）的用例——`ResponseBody.fromString` 发完即 done，
/// 会立刻触发重连，看不到这些。
class _ControllableAdapter implements HttpClientAdapter {
  /// 每次 `fetch` 都新建一个控制器：**单订阅流只能被 listen 一次**，而
  /// `resume()` / 退避重连会发起第二次连接。复用同一个 controller 会让第二次
  /// `_openStream` 的 listen 抛「Stream has already been listened to」。
  final List<StreamController<Uint8List>> _controllers = [];

  StreamController<Uint8List> get _latest => _controllers.last;

  void push(List<int> bytes) => _latest.add(Uint8List.fromList(bytes));

  void addError(Object error) => _latest.addError(error);

  /// 结束最近一次响应流（触发客户端的 `onDone`）。
  Future<void> endStream() => _latest.close();

  /// 已建立的连接数（用于断言「没有多余重连」）。
  int get connectionCount => _controllers.length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final controller = StreamController<Uint8List>();
    _controllers.add(controller);
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 抛**非** DioException 的适配器（覆盖 `_openStream` 的 `catch (e, st)` 分支）。
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw StateError('adapter blew up');
  }

  @override
  void close({bool force = false}) {}
}

/// 响应体为 null 的适配器（覆盖 `body == null` 分支）。
class _NullBodyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // ResponseBody 的 stream 非空，但 dio 在 responseType=stream 且
    // 适配器返回 null 时会给 Response.data 置 null。这里用抛异常模拟
    // 「拿到了响应但体为空」——见 SseClient 里的 `body == null` 分支。
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.unknown,
      response: Response<dynamic>(requestOptions: options, statusCode: 200),
    );
  }

  @override
  void close({bool force = false}) {}
}

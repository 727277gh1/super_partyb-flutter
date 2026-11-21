/// **纯 Dart 端到端**：真实 HTTP + 真实 SSE 字节流 → `SseClient` 解析。
///
/// ## 这个测试补的是什么（issue #48 第三部分）
///
/// 拆分前的状态是：`SseClient` 自己的单测（`sse_client_test.dart`）用
/// `DioAdapter` 造 `ResponseBody.stream`，而上层（`ChatStreamController`）
/// 用 `FakeSseClient`。**没有任何一条测试跨过「真实 socket → 真实分片 →
/// 真实 UTF-8 增量解码 → 真实 SSE 行解析」**这一整条链路——issue #41 修的
/// 「分片切开 UTF-8 导致静默损坏」正是这条链路上的缺陷，而它是被
/// `DioAdapter` 喂**完整字节数组**掩盖的。
///
/// ## 为什么用 `dart:io HttpServer` 而不是 `integration_test/`
///
/// 本文件是**纯 Dart**（无 `flutter_test`、无 Flutter 引擎）：
/// - 不需要 `DISPLAY`（本机无，见 AGENTS.md §9）；
/// - 可以 `dart test` 直接跑，不需要 `xvfb-run`；
/// - 覆盖的正是「网络层」这一最有价值、而此前完全空白的部分。
///
/// ⚠️ 这**不推翻** AGENTS.md §6.20「`integration_test/` 第 3 层有意不做」——
/// 那个决策针对的是「真机 + UI 集成测试」，与本文件的成本/收益都不同。
///
/// ## 覆盖的分支
///
/// | 用例 | 链路 |
/// |---|---|
/// | 基本事件流 | 真实 socket → 多帧 → `event`/`data`/`id` 解析 |
/// | 多行 `data:` 拼接 | SSE 规范：同一帧的多个 `data:` 行以 `\n` 连接 |
/// | `: heartbeat` 注释帧 | 不进业务流（`isComment == true`） |
/// | **UTF-8 跨分片** | issue #41 的真实缺陷：多字节字符被 socket 分片切开 |
/// | 分片边界落在 `\r\n` 之间 | CRLF 分片不能丢事件 |
/// | 空行分隔 | 只有空行才 flush 帧 |
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:test/test.dart';

/// 起一个真实 HTTP 服务器，按 [script] 逐块写 SSE 字节后关闭。
///
/// [script] 收到一个 `void Function(List<int> bytes)`；测试用它精确控制
/// 分片边界（这是本文件存在的理由——`DioAdapter` 做不到）。
Future<SseServer> startSseServer(
  Future<void> Function(void Function(List<int>) write) script, {
  int? statusCode,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <HttpRequest>[];
  unawaited(() async {
    await for (final req in server) {
      requests.add(req);
      final res = req.response;
      if (statusCode != null) {
        res.statusCode = statusCode;
        await res.close();
        continue;
      }
      res.statusCode = 200;
      res.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream');
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      await res.flush();
      await script((bytes) => res.add(bytes));
      await res.flush();
      await res.close();
    }
  }());
  return SseServer(server, requests);
}

class SseServer {
  SseServer(this.server, this.requests);
  final HttpServer server;
  final List<HttpRequest> requests;
  String get baseUrl => 'http://${server.address.host}:${server.port}';
  Future<void> close() => server.close(force: true);
}

/// 编码成 UTF-8 字节（模拟服务端写出）。
List<int> enc(String s) => utf8.encode(s);

/// 等 `SseClient` 收到至少 [n] 帧（或超时）。
Future<List<SseFrame>> collect(
  SseClient client,
  int n, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final out = <SseFrame>[];
  final done = Completer<void>();
  final sub = client.frames.listen((f) {
    out.add(f);
    if (out.length >= n && !done.isCompleted) done.complete();
  });
  return done.future.timeout(timeout, onTimeout: () {}).then((_) async {
    await sub.cancel();
    return out;
  });
}

SseClient makeClient(String baseUrl) => SseClient(
  dio: Dio(
    BaseOptions(
      // 真实 socket 也要有上限，避免用例挂死。
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  ),
  baseUrl: baseUrl,
  initialBackoff: const Duration(milliseconds: 10),
  maxBackoff: const Duration(milliseconds: 50),
  maxRetries: 1,
);

void main() {
  group('真实 HTTP + SSE 端到端（issue #48 第三部分）', () {
    test('基本事件流：真实 socket → 多帧 → event/data/id 解析', () async {
      final srv = await startSseServer((write) async {
        write(enc('id: 1\nevent: message\ndata: {"a":1}\n\n'));
        write(enc('id: 2\nevent: done\ndata: {"b":2}\n\n'));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final collecting = collect(client, 2);
      await client.connect(path: '/users/u1/chat/stream');
      final frames = await collecting;

      expect(frames, hasLength(2));
      expect(frames[0].id, '1');
      expect(frames[0].event, 'message');
      expect(frames[0].data, '{"a":1}');
      expect(frames[1].id, '2');
      expect(frames[1].event, 'done');
      expect(frames[1].data, '{"b":2}');
    });

    test('多行 data: 按 SSE 规范以 \\n 拼接', () async {
      final srv = await startSseServer((write) async {
        // 服务端把一帧拆成多个 data 行（长 payload 的合法写法）。
        write(enc('event: message\ndata: {"a":\ndata: 1}\n\n'));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final collecting = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      final frames = await collecting;

      expect(frames, hasLength(1));
      expect(frames.single.data, '{"a":\n1}');
    });

    test('`: heartbeat` 注释帧不进业务流，且不干扰其后的帧', () async {
      final srv = await startSseServer((write) async {
        write(enc(': heartbeat\n\n'));
        write(enc('event: message\ndata: x\n\n'));
        write(enc(': heartbeat\n\n'));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      // 注释帧也走 frames 流（`isComment == true`），故这里收 3 帧。
      final collecting = collect(client, 3);
      await client.connect(path: '/users/u1/chat/stream');
      final frames = await collecting;

      expect(frames, hasLength(3));
      expect(frames[0].isComment, isTrue);
      expect(frames[1].isComment, isFalse);
      expect(frames[1].data, 'x');
      expect(frames[2].isComment, isTrue);
    });

    test('**UTF-8 跨分片**：多字节字符被切开仍能正确解码（issue #41）', () async {
      final srv = await startSseServer((write) async {
        // 「你好」= E4 BD A0 E5 A5 BD。故意在**第 1 个字节后**切断：
        // 分片 1 以 E4 结尾（不完整的 3 字节序列）。
        final payload = enc('event: message\ndata: 你好\n\n');
        final cut = payload.indexOf(0xE4) + 1;
        write(payload.sublist(0, cut));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        write(payload.sublist(cut));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final collecting = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      final frames = await collecting;

      expect(frames, hasLength(1));
      expect(
        frames.single.data,
        '你好',
        reason:
            '增量解码器必须跨分片保留不完整序列；'
            '若每片独立 decode，会得到「你\uFFFD」这样的静默损坏',
      );
    });

    test('UTF-8 在**每个字节**之间分片（最坏情况）', () async {
      final srv = await startSseServer((write) async {
        for (final b in enc('event: message\ndata: 中文测试🎉\n\n')) {
          write([b]);
        }
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final collecting = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      final frames = await collecting;

      expect(frames, hasLength(1));
      expect(frames.single.data, '中文测试🎉', reason: '含 4 字节 emoji');
    });

    test('分片边界落在 \\r\\n 之间不丢事件', () async {
      final srv = await startSseServer((write) async {
        // CRLF 结尾的 SSE（规范允许）。切在 \r 与 \n 之间。
        final payload = enc('event: message\r\ndata: x\r\n\r\n');
        final cr = payload.indexOf(0x0D);
        write(payload.sublist(0, cr + 1)); // 到 \r 为止
        await Future<void>.delayed(const Duration(milliseconds: 5));
        write(payload.sublist(cr + 1));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final collecting = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      final frames = await collecting;

      expect(frames, hasLength(1));
      expect(frames.single.data, 'x');
    });

    test('同一帧跨多个分片（逐字节）仍解析出完整帧', () async {
      final srv = await startSseServer((write) async {
        for (final b in enc('id: 9\nevent: message\ndata: hello\n\n')) {
          write([b]);
        }
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final collecting = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      final frames = await collecting;

      expect(frames, hasLength(1));
      expect(frames.single.id, '9');
      expect(frames.single.event, 'message');
      expect(frames.single.data, 'hello');
    });

    test('连接建立时带 Accept: text/event-stream 头', () async {
      final srv = await startSseServer((write) async {
        write(enc('data: ok\n\n'));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final collecting = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      await collecting;

      expect(srv.requests, hasLength(1));
      expect(
        srv.requests.single.headers.value(HttpHeaders.acceptHeader),
        'text/event-stream',
        reason: '部分 CDN / 代理会按 Accept 决定是否缓冲响应',
      );
    });

    test('首次 connect 不带 cursor（cursor 只在 resume / 重连时用）', () async {
      final srv = await startSseServer((write) async {
        write(enc('id: 7\nevent: message\ndata: a\n\n'));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final collecting = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      await collecting;

      expect(
        srv.requests.single.uri.queryParameters.containsKey('cursor'),
        isFalse,
      );
    });

    test('resume 带上层记录的 eventId 作 cursor（真实 socket 上的回放契约）', () async {
      final srv = await startSseServer((write) async {
        write(enc('id: 42\nevent: message\ndata: a\n\n'));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final first = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      await first;

      // ⚠️ **cursor 由上层显式记录**，不由收到 `id:` 自动接管——
      // `recordEventId` 的文档写明「只有落库事件才有有效 ID，Transient 事件
      // （流式增量）的 ID 不能作为 cursor，否则重连会跳过它们之后落库的
      // 权威帧」。故这里模拟上层的调用，而不是指望 `_onText` 自动记。
      client.recordEventId('42');

      final second = collect(client, 1);
      await client.resume();
      await second;

      expect(srv.requests, hasLength(2));
      expect(
        srv.requests[1].uri.queryParameters['cursor'],
        '42',
        reason:
            'cursor 是「回放其后的事件」的锚点；'
            '服务端上限 500 条，超出窗口返回空 → 上层改走 timeline 回填',
      );
    });

    test('未 recordEventId 时 resume 不带 cursor（不编造锚点）', () async {
      final srv = await startSseServer((write) async {
        write(enc('id: 42\nevent: message\ndata: a\n\n'));
      });
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final first = collect(client, 1);
      await client.connect(path: '/users/u1/chat/stream');
      await first;

      final second = collect(client, 1);
      await client.resume();
      await second;

      expect(
        srv.requests[1].uri.queryParameters.containsKey('cursor'),
        isFalse,
        reason: '收到过 `id:` 不等于它是可用的 cursor——那要由上层判断',
      );
    });

    test('服务端 401 → 进入 failed 且不重试（不可恢复错误）', () async {
      final srv = await startSseServer((write) async {}, statusCode: 401);
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      final states = <SseState>[];
      final sub = client.states.listen(states.add);
      addTearDown(sub.cancel);

      await client.connect(path: '/users/u1/chat/stream');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(states, contains(SseState.failed));
      expect(
        srv.requests,
        hasLength(1),
        reason:
            '401 不可恢复（重试只会拿到同一个 401），'
            '与 5xx/网络错误的重试语义不同',
      );
    });

    test('服务端 500 → 退避后重连（可重试错误）', () async {
      final srv = await startSseServer((write) async {}, statusCode: 500);
      addTearDown(srv.close);
      final client = makeClient(srv.baseUrl);
      addTearDown(client.close);

      await client.connect(path: '/users/u1/chat/stream');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        srv.requests.length,
        greaterThan(1),
        reason: '5xx 是瞬时的（部署重启、上游抖动），应退避重连',
      );
    });
  });
}

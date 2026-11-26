import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 群忙缓冲（`202 deferred`）在客户端的时间线语义（issue #113）
///
/// 服务端（super_partyb#168）在群正忙时**不建 turn**，把输入塞进
/// `chat_inbox_messages(pending)` 并回：
///
/// ```json
/// 202 {"turn_id":"","group_id":"…","status":"deferred","deferred":true,
///      "inbox_message_id":"inbox_7"}
/// ```
///
/// 客户端有两条错误路线，本文件各锁一条：
///
/// 1. **当普通成功转正** → 用户看到「已发送」，然后安静几分钟（真正开跑要等
///    当前 turn 终态）；
/// 2. **一直停在「发送中」** → group 被归档时服务端把缓冲标 `superseded`，
///    永远不会有那一轮，气泡永久转圈（§6.50 消灭过的失败模式）。
///
/// 正确语义：保持「发送中」，等续跑那一轮的 `user_message`（payload 里带**同一个**
/// `inbox_message_id`）到达时**原位吸收**——否则会多出一个重复气泡（去重是按
/// turnId 的，而排队中的回显还没有 turnId）。超时只关「发送中」，不丢消息。

/// 只控制 POST 返回时机的适配器（GET 立即放行，避免阻塞 timeline 回填）。
class _HangAdapter implements HttpClientAdapter {
  final _pending = <Completer<ResponseBody>>[];

  int get hanging => _pending.length;

  Future<void> waitForRequest() async {
    for (var i = 0; i < 50 && _pending.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    if (_pending.isEmpty) throw StateError('请求未到达适配器（send 未发出？）');
  }

  void resolve(Map<String, dynamic> json, {int code = 202}) {
    _pending.removeLast().complete(
      ResponseBody.fromString(
        jsonEncode(json),
        code,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.method.toUpperCase() != 'POST') {
      return Future.value(
        ResponseBody.fromString(
          jsonEncode({'items': <dynamic>[], 'next_before_global_seq': ''}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
    }
    final c = Completer<ResponseBody>();
    _pending.add(c);
    return c.future;
  }

  @override
  void close({bool force = false}) {}
}

ChatStreamController _controllerWith(_HangAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test/pba'))
    ..httpClientAdapter = adapter;
  return ChatStreamController(sse: sse, api: ChatApi(dio), userId: 'usr_1');
}

/// 推一条「续跑那一轮」的权威 user_message，带缓冲消息的 id。
Future<void> _pushDrainedFrames({
  required ChatStreamController c,
  required String inboxMessageId,
  required String turnId,
  required String input,
  String eventId = 'srv_1',
}) async {
  sse.push(
    EventTypes.userMessage,
    sseEvent(
      EventTypes.userMessage,
      id: eventId,
      turnId: turnId,
      payload: {'input': input, 'inbox_message_id': inboxMessageId},
    ),
  );
  // broadcast 流的投递是异步的，不先转一个轮次就 flushEmit 看到的是旧缓冲。
  await Future<void>.delayed(Duration.zero);
  c.flushEmit();
}

void main() {
  setUpHarness();

  group('群忙缓冲（issue #113）', () {
    test('deferred 响应：气泡保持「发送中」，不落 turnId，也不记 lastSentTurnId', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '补一句', groupId: 'grp_1');
      c.flushEmit();
      await hang.waitForRequest();

      hang.resolve({
        'turn_id': '',
        'group_id': 'grp_1',
        'status': 'deferred',
        'deferred': true,
        'inbox_message_id': 'inbox_7',
      });
      final result = await sending;
      expect(result.deferred, isTrue);
      c.flushEmit();

      final item = c.snapshot.single as UserMessageItem;
      expect(item.text, '补一句');
      expect(item.pending, isTrue, reason: '还没真正开跑，不能显示成「已发送」');
      expect(item.turnId, isEmpty);
      expect(c.lastSentTurnId, isEmpty, reason: '没有 turn 可等，不能让对话页进入「正在准备响应」');

      await c.dispose();
    });

    test('续跑那一轮到达：回显被原位吸收，时间线仍只有一条', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');

      final sending = c.send(input: '排队的一句', groupId: 'grp_1');
      c.flushEmit();
      await hang.waitForRequest();
      hang.resolve({
        'turn_id': '',
        'group_id': 'grp_1',
        'status': 'deferred',
        'deferred': true,
        'inbox_message_id': 'inbox_7',
      });
      await sending;
      c.flushEmit();
      expect((c.snapshot.single as UserMessageItem).pending, isTrue);

      await _pushDrainedFrames(
        c: c,
        inboxMessageId: 'inbox_7',
        turnId: 'turn_real',
        input: '排队的一句',
      );

      final items = c.snapshot.whereType<UserMessageItem>().toList();
      expect(items, hasLength(1), reason: '吸收靠 inbox_message_id，不是再冒一个气泡');
      expect(items.single.pending, isFalse, reason: '已经开跑了');
      expect(items.single.turnId, 'turn_real');
      expect(items.single.id, 'srv_1', reason: '原位替换成服务端权威项');
      expect(c.lastSentTurnId, 'turn_real', reason: '现在有 turn 可等了');

      await c.dispose();
    });

    test('inbox_message_id 不匹配的 user_message：照常渲染，不吞别人的消息', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');

      final sending = c.send(input: '排队的一句', groupId: 'grp_1');
      c.flushEmit();
      await hang.waitForRequest();
      hang.resolve({
        'turn_id': '',
        'group_id': 'grp_1',
        'status': 'deferred',
        'deferred': true,
        'inbox_message_id': 'inbox_7',
      });
      await sending;
      c.flushEmit();

      // 另一个客户端（或别的缓冲消息）开跑的轮次。
      await _pushDrainedFrames(
        c: c,
        inboxMessageId: 'inbox_other',
        turnId: 'turn_other',
        input: '别人的一句',
      );

      final items = c.snapshot.whereType<UserMessageItem>().toList();
      expect(items, hasLength(2), reason: '不匹配就各归各的，排队那条继续等');
      expect(items.where((i) => i.pending).length, 1);

      await c.dispose();
    });

    test('相似文本但不同 inbox_message_id：按 id 对齐，不按文本猜', () async {
      // 用户完全可能连发两条一样的「继续」。若按文本相似度吸收，第二条会被
      // 并到第一条的气泡上，时间线上少一条、模型却看到两条输入。
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');

      final sending = c.send(input: '继续', groupId: 'grp_1');
      c.flushEmit();
      await hang.waitForRequest();
      hang.resolve({
        'turn_id': '',
        'group_id': 'grp_1',
        'status': 'deferred',
        'deferred': true,
        'inbox_message_id': 'inbox_7',
      });
      await sending;
      c.flushEmit();

      await _pushDrainedFrames(
        c: c,
        inboxMessageId: 'inbox_8',
        turnId: 'turn_x',
        input: '继续',
      );

      final items = c.snapshot.whereType<UserMessageItem>().toList();
      expect(items, hasLength(2), reason: '同样文本、不同 inbox id → 两条');
      expect(items.last.turnId, 'turn_x');

      await c.dispose();
    });

    test('缺 inbox_message_id 的 deferred 响应：退化成普通落地，不永久转圈', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '缺字段的一句', groupId: 'grp_1');
      c.flushEmit();
      await hang.waitForRequest();
      hang.resolve({
        'turn_id': '',
        'group_id': 'grp_1',
        'status': 'deferred',
        'deferred': true,
      });
      await sending;
      c.flushEmit();

      final item = c.snapshot.single as UserMessageItem;
      expect(item.pending, isFalse, reason: '没有凭据可等，就别让用户看着转圈');
      expect(item.text, '缺字段的一句');

      await c.dispose();
    });

    test('续跑一直不来：超时只关「发送中」，气泡仍在，晚到的续跑帧仍能吸收', () async {
      // 一条气泡永久转圈是 §6.50 记录过的失败模式。服务端把缓冲标 superseded
      // （group 被归档）时**永远不会**有那一轮，所以超时必须有兜底。
      //
      // 但到期不能丢消息也不能放弃对齐：登记继续保留（默认 6h），晚到的续跑帧
      // 依然原位吸收，而不是在时间线上再冒一条。
      //
      // 用真实计时器 + 缩短的超时窗口（而不是 fakeAsync）：订阅、dio 拦截器、
      // 广播流三处都是真实异步，fakeAsync 里要手工喂轮次，反而容易测出「框架
      // 时序」而不是「控制器语义」。
      final hang = _HangAdapter();
      final c = _controllerWith(hang)
        ..deferredSettleTimeout = const Duration(milliseconds: 20);
      await c.start(groupId: 'grp_1');

      final sending = c.send(input: '排很久的一句', groupId: 'grp_1');
      c.flushEmit();
      await hang.waitForRequest();
      hang.resolve({
        'turn_id': '',
        'group_id': 'grp_1',
        'status': 'deferred',
        'deferred': true,
        'inbox_message_id': 'inbox_7',
      });
      await sending;
      c.flushEmit();
      expect((c.snapshot.single as UserMessageItem).pending, isTrue);

      // 超时到点：只关「发送中」。
      await Future<void>.delayed(const Duration(milliseconds: 60));
      c.flushEmit();

      final item = c.snapshot.single as UserMessageItem;
      expect(item.pending, isFalse, reason: '不能永久转圈');
      expect(item.turnId, isEmpty);
      expect(item.text, '排很久的一句', reason: '消息不能因为超时就消失');

      // 晚到的续跑帧：仍然原位吸收（登记保留到 6h），不产生第二条。
      await _pushDrainedFrames(
        c: c,
        inboxMessageId: 'inbox_7',
        turnId: 'turn_late',
        input: '排很久的一句',
        eventId: 'srv_late',
      );

      final items = c.snapshot.whereType<UserMessageItem>().toList();
      expect(items, hasLength(1), reason: '晚到的续跑帧也要合并，不能变两条');
      expect(items.single.turnId, 'turn_late');
      expect(items.single.pending, isFalse);

      await c.dispose();
    });
  });
}

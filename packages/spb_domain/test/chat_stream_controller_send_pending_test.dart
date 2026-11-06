import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 乐观回显的 pending 生命周期（issue #52）
///
/// [ChatStreamController.send] 在请求在飞时注入 `pending: true` 的本地回显；
/// 响应到达后转正（关 pending、落 turnId）或移除（失败 / 入队）。本文件用
/// **可控适配器**把「响应还没回来」这个窗口做成确定性的——`http_mock_adapter`
/// 的 reply 是立即完成的，表达不出「在飞」这一时序。
///
/// 共享夹具见 `support/chat_stream_controller_harness.dart`。
/// 挂起 POST 响应、由测试手动放行的适配器。
///
/// 只劫持 `fetch` 的**返回时机**，响应形状照常走 json——这样「响应到达」
/// 与「转正」的先后由测试完全掌控。
///
/// ⚠️ 必须是**顶层**类：Dart 的局部类不能被内层闭包引用，而每个用例都是闭包。
class _HangAdapter implements HttpClientAdapter {
  final _pending = <Completer<ResponseBody>>[];

  /// 已收到但未放行的请求数。
  int get hanging => _pending.length;

  /// 等到请求真正到达适配器。
  ///
  /// ⚠️ 不能只 `await Future.delayed(Duration.zero)` 一次：dio 的拦截器链
  /// 要走**三个**事件循环任务才调到 `fetch`（实测：第 1、2 轮 `calls == 0`，
  /// 第 3 轮才 1）。等一次就 `resolve` 会作用在空队列上（`removeLast` 抛
  /// RangeError），而那看起来像「控制器有 bug」，实则是测试时序写错。
  Future<void> waitForRequest() async {
    for (var i = 0; i < 50 && _pending.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    if (_pending.isEmpty) throw StateError('请求未到达适配器（send 未发出？）');
  }

  void resolve(Map<String, dynamic> json, {int code = 201}) {
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

  void reject(Object error) => _pending.removeLast().completeError(error);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    // GET（timeline 回填）立即放行：本适配器只控制 POST 的时机。
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

void main() {
  setUpHarness();

  group('乐观回显：请求在飞（issue #52）', () {
    test('请求在飞时时间线已出现这条消息，且带 pending（不等响应）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '在飞的一句话', groupId: 'grp_1');
      // 注入是同步的，但归约被合并到事件循环任务（issue #44）——显式跑一次。
      c.flushEmit();

      final items = c.snapshot;
      expect(items, hasLength(1), reason: '响应未回，消息必须先渲染出来');
      final item = items.single as UserMessageItem;
      expect(item.text, '在飞的一句话');
      expect(item.pending, isTrue, reason: '在飞 → UI 显示「发送中」');
      expect(item.turnId, isEmpty, reason: '服务端尚未分配 turnId');

      await hang.waitForRequest();
      expect(hang.hanging, 1);

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      await c.dispose();
    });

    test('响应到达后原位转正：pending 关掉、turnId 落上，且不新增第二条', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '等转正的一句话', groupId: 'grp_1');
      c.flushEmit();
      expect((c.snapshot.single as UserMessageItem).pending, isTrue);

      await hang.waitForRequest();

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      c.flushEmit();

      final items = c.snapshot;
      expect(items, hasLength(1), reason: '转正是原位替换，不是再注入一条');
      final item = items.single as UserMessageItem;
      expect(item.pending, isFalse);
      expect(item.turnId, 'turn_9');

      await c.dispose();
    });

    test('转正记下 lastSentTurnId，且结构推断为 preparing（对话页据此提示）', () async {
      // 「请求在飞 → 转正」这一段是**唯一**能把 turnId 交给界面的时机，而对话页
      // 的「正在准备响应」细条完全依赖它：pending 期间 turnId 为空（无从判断），
      // 转正后才知道该盯哪个 turn。两件事必须在同一条路径上落定，否则界面会
      // 一直等到首个增量帧——那正是用户报障的空窗。
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '发出去', groupId: 'grp_1');
      c.flushEmit();
      expect(c.lastSentTurnId, isEmpty, reason: '请求在飞时还不知道 turnId');

      await hang.waitForRequest();
      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      c.flushEmit();

      expect(c.lastSentTurnId, 'turn_9');
      // 同一时刻的结构推断：只有用户项、无终态 → preparing（与看门狗武装
      // 计时器同一判据，故「界面说在等」与「超时兜底」不会互相矛盾）。
      final run = c.lastTurnRunSnapshot;
      expect(run.state, LastTurnRunState.preparing);
      expect(run.turnId, 'turn_9');

      await c.dispose();
    });

    test('权威 user_message 帧随后到达：仍只有一条（按 turnId 原位合并）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      // 必须先 start：帧订阅在 start 里建立（`_frameSub ??=`），而它会清空
      // 缓冲——故放在 send 之前。
      await c.start(groupId: 'grp_1');

      final sending = c.send(input: '会被合并的一句话', groupId: 'grp_1');
      c.flushEmit();

      await hang.waitForRequest();

      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      // 服务端把 user_message 放进 broadcasts（enqueue.go），确实经 SSE 推。
      sse.push(
        EventTypes.userMessage,
        sseEvent(
          EventTypes.userMessage,
          id: 'srv_1',
          turnId: 'turn_9',
          payload: {'input': '会被合并的一句话'},
        ),
      );
      // ⚠️ broadcast 流的投递是异步的，不先转一个轮次就 flushEmit 看到的是
      // **旧缓冲**（帧还没进 `_buffer`）。
      await Future<void>.delayed(Duration.zero);
      c.flushEmit();

      final items = c.snapshot.whereType<UserMessageItem>().toList();
      expect(items, hasLength(1), reason: '去重靠转正后的 turnId');
      expect(items.single.pending, isFalse);
      expect(items.single.id, 'srv_1', reason: '原位替换成服务端权威项');

      await c.dispose();
    });

    test('turnId 为空的响应（feedback_recorded 不建 turn）：不得把回显永久留在「发送中」', () async {
      // 反馈类响应没有 turn、**不会再有权威帧**到达。若转正在 turnId 为空时
      // 提前 return，这条气泡会带着 pending 永远转圈（修复前的真实缺陷）。
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '准确', groupId: 'grp_1');
      c.flushEmit();
      expect((c.snapshot.single as UserMessageItem).pending, isTrue);

      await hang.waitForRequest();

      hang.resolve({'status': 'feedback_recorded', 'group_id': 'grp_1'});
      final result = await sending;
      expect(result.turnId, isEmpty);
      c.flushEmit();

      final item = c.snapshot.single as UserMessageItem;
      expect(item.pending, isFalse, reason: '响应已落地，「发送中」必须关掉');
      expect(item.turnId, isEmpty);
      expect(item.text, '准确', reason: '反馈原文保留在时间线上');

      await c.dispose();
    });

    test('失败（不可重试）→ 回显移除，不留幽灵消息', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '会失败的一句话', groupId: 'grp_1');
      c.flushEmit();
      expect(c.snapshot, hasLength(1));

      await hang.waitForRequest();

      hang.reject(const HttpError(400, 'bad request'));
      await expectLater(sending, throwsA(isA<SpbError>()));
      c.flushEmit();

      expect(c.snapshot, isEmpty, reason: '失败的消息不能永久停在时间线上');

      await c.dispose();
    });

    test('可重试失败 → 回显移除且消息进队列（「待发送」条是另一个 UI）', () async {
      final hang = _HangAdapter();
      final store = FakeOutboxStore();
      final c = ChatStreamController(
        sse: sse,
        api: ChatApi(
          Dio(BaseOptions(baseUrl: 'https://api.test/pba'))
            ..httpClientAdapter = hang,
        ),
        userId: 'usr_1',
        outbox: queueFor(store, fail: const NetworkError('投递也断')),
      );

      final sending = c.send(input: '断网时写的一句话', groupId: 'grp_1');
      c.flushEmit();
      expect(c.snapshot, hasLength(1));

      await hang.waitForRequest();

      hang.reject(const NetworkError('断网'));
      await expectLater(sending, throwsA(isA<MessageQueuedError>()));
      c.flushEmit();

      expect(c.snapshot, isEmpty, reason: '入队条目不进时间线（issue #30）');
      expect(store.rows, hasLength(1));

      await c.dispose();
    });

    test('乐观回显不得推进 SSE 游标（transient 不变式，pending 路径同理）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);
      await c.start(groupId: 'grp_1');

      // 先推进一个**落库**事件作为参照：它应该被记进游标。
      sse.push(
        EventTypes.userMessage,
        sseEvent(EventTypes.userMessage, id: 'srv_1', turnId: 'turn_srv'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sse.recordedEventIds, ['srv_1']);

      final sending = c.send(input: '不占游标', groupId: 'grp_1');
      c.flushEmit();
      await hang.waitForRequest();
      hang.resolve({'turn_id': 'turn_9', 'group_id': 'grp_1'});
      await sending;
      c.flushEmit();

      // 注入与转正都是本地合成事件：若推进游标，重连回放会跳过其后的
      // 权威帧（§5.4）。游标必须仍只有服务那条。
      expect(sse.recordedEventIds, ['srv_1']);

      await c.dispose();
    });

    test('两次注入落在同一微秒也不得共用 eventId（转正/移除按 id 精确定位）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      // outbox 批量投递等路径可能同一微秒连续注入；id 撞了会让转正命中错误的
      // 回显。显式传同一个 createdAt 复现碰撞条件，并验证 id 定位正确：
      // send() 的转正只应关掉**它自己那条**的 pending，先注入的两条不受牵连。
      final at = DateTime.now().toUtc();
      final id1 = c.injectLocalUserMessage(
        input: '第一条',
        groupId: 'grp_1',
        createdAt: at,
        pending: true,
      );
      final id2 = c.injectLocalUserMessage(
        input: '第二条',
        groupId: 'grp_1',
        createdAt: at,
        pending: true,
      );
      // 直接钉唯一性契约：id 是转正/移除的精确定位键（[ChatStreamController.
      // _settleLocalEcho] 按 eventId 索引），碰撞会让写入命中错误的回显。
      // ⚠️ 别删这条去依赖下面的间接断言——后者在 id 碰撞时依然绿（
      // send 的回显 id 不受影响，转正命中的是第一条而非第三条，「两条
      // pending 都还在」照样成立）。实测踩过。
      expect(id1, isNot(id2));

      final sending = c.send(input: '第三条', groupId: 'grp_1');
      await hang.waitForRequest();
      hang.resolve({'turn_id': 'turn_3', 'group_id': 'grp_1'});
      await sending;
      c.flushEmit();

      final items = c.snapshot.whereType<UserMessageItem>().toList();
      expect(items, hasLength(3));
      expect(
        items.where((i) => i.pending).map((i) => i.text),
        unorderedEquals(<String>['第一条', '第二条']),
        reason: '只有转正的那条关掉了 pending，同微秒注入的其余两条不受牵连',
      );

      await c.dispose();
    });
  });

  group('乐观回显：在飞期间的生命周期交互', () {
    test('在飞期间切 group（缓冲被清空）：响应到达后不得把旧消息塞进新对话', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '跨组的一句话', groupId: 'grp_1');
      c.flushEmit();
      expect(c.snapshot, hasLength(1));

      // 切到另一个 group：_backfill 会清空缓冲并拉新历史（GET 由适配器直接放行）。
      await c.switchGroup('grp_2');
      expect(c.snapshot, isEmpty);

      await hang.waitForRequest();

      hang.resolve({'turn_id': 'turn_x', 'group_id': 'grp_1'});
      await sending;
      c.flushEmit();

      expect(
        c.snapshot.whereType<UserMessageItem>(),
        isEmpty,
        reason: '旧对话的消息不能渲染进新对话的时间线',
      );

      await c.dispose();
    });

    test('响应在 dispose 之后到达：不得抛（流已关闭）', () async {
      final hang = _HangAdapter();
      final c = _controllerWith(hang);

      final sending = c.send(input: '迟到的一句话', groupId: 'grp_1');
      c.flushEmit();

      await c.dispose();
      await hang.waitForRequest();
      hang.resolve({'turn_id': 'turn_late', 'group_id': 'grp_1'});

      // settle 会往已关闭的流 add——必须被 isClosed 守卫吞掉而不是抛
      // 「Cannot add event after closing」。
      await expectLater(sending, completes);
    });
  });
}

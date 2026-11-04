import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `routing_selected` → 气泡徽标 / 回退提示行的归约测试。
///
/// 背景：服务端把 `routing_selected` 与 `user_message` 放进**同一个入队事务**，
/// 顺序保证 user_message 在前（Go `chat/enqueue.go`）。此前归约器对每条
/// `routing_selected` 都产一行 `RoutingNoticeItem`——对话内发送的常态
/// （`fixed_reuse`）是零信息量的，每个 turn 都多一行，把正文挤出视野。
void main() {
  /// 造一个事件（与 event_reducer_test.dart 同构）。
  ChatEvent ev(
    String type, {
    String id = '',
    String turnId = 'turn_1',
    Map<String, dynamic>? payload,
    bool transient = false,
    int seq = 1,
    int globalSeq = 1,
  }) => ChatEvent(
    eventId: id.isEmpty ? '${type}_$globalSeq' : id,
    userId: 'usr_1',
    groupId: 'grp_1',
    turnId: turnId,
    eventType: type,
    seq: seq,
    globalSeq: transient ? null : globalSeq,
    source: 'test',
    createdAt: DateTime.utc(2024, 3, 5, 8, 9, globalSeq.clamp(0, 59)),
    payload: payload,
    transient: transient,
  );

  ChatEvent userMsg({
    String id = 'evt_user',
    String turnId = 'turn_1',
    String text = '帮我看看这个报错',
    int globalSeq = 1,
  }) => ev(
    EventTypes.userMessage,
    id: id,
    turnId: turnId,
    globalSeq: globalSeq,
    payload: {'input': text},
  );

  ChatEvent routing({
    String reason = 'fixed_reuse',
    bool switched = false,
    String turnId = 'turn_1',
    String id = 'evt_routing',
    int globalSeq = 2,
    Map<String, dynamic>? extra,
  }) => ev(
    EventTypes.routingSelected,
    id: id,
    turnId: turnId,
    globalSeq: globalSeq,
    payload: {
      'group_decision_reason': reason,
      'selected_group_id': 'grp_9',
      if (switched) 'group_switched': true,
      ...?extra,
    },
  );

  group('routing_selected 合并进同 turn 用户气泡', () {
    test('fixed_reuse：不产 RoutingNoticeItem，气泡也不带徽标数据', () {
      final r = EventReducer.reduce([
        userMsg(),
        routing(reason: 'fixed_reuse', switched: false),
      ]);

      final user = r.items.whereType<UserMessageItem>().single;
      expect(user.routingReason, 'fixed_reuse');
      expect(user.routingSwitched, isFalse);
      expect(r.items.whereType<RoutingNoticeItem>(), isEmpty);
    });

    test('气泡 id / 文本 / 位置不变（合并不重挂）', () {
      final r = EventReducer.reduce([userMsg(id: 'evt_user_1'), routing()]);

      final user = r.items.whereType<UserMessageItem>().single;
      expect(user.id, 'evt_user_1');
      expect(user.text, '帮我看看这个报错');
      expect(r.items, hasLength(1));
    });

    test('create_new：合并进气泡（新建对话），不产独立提示行', () {
      final r = EventReducer.reduce([userMsg(), routing(reason: 'create_new')]);

      final user = r.items.whereType<UserMessageItem>().single;
      expect(user.routingReason, 'create_new');
      expect(user.routingSwitched, isFalse);
      expect(r.items.whereType<RoutingNoticeItem>(), isEmpty);
    });

    test('group_switched：合并进气泡（静默切换），不产独立提示行', () {
      final r = EventReducer.reduce([
        userMsg(),
        routing(reason: 'classify_reuse', switched: true),
      ]);

      final user = r.items.whereType<UserMessageItem>().single;
      expect(user.routingReason, 'classify_reuse');
      expect(user.routingSwitched, isTrue);
      expect(r.items.whereType<RoutingNoticeItem>(), isEmpty);
    });

    test('未知原因：合并进气泡（fail-open，UI 原样透传）', () {
      final r = EventReducer.reduce([
        userMsg(),
        routing(reason: 'brand_new_kind'),
      ]);

      expect(
        r.items.whereType<UserMessageItem>().single.routingReason,
        'brand_new_kind',
      );
      expect(r.items.whereType<RoutingNoticeItem>(), isEmpty);
    });

    test('合并保留 agentId（agent_id 继承与归属合并不互相冲掉）', () {
      // 乐观回显带 agent_id + pending；服务端 user_message（不带 agent_id）先
      // 原位替换并保留它；routing_selected 再合并时**必须继续保留**。
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          id: 'local-1',
          globalSeq: 0,
          transient: true,
          payload: {'input': 'hi', 'agent_id': 'agt_a', 'pending': true},
        ),
        userMsg(id: 'evt_user'),
        routing(reason: 'create_new'),
      ]);

      final user = r.items.whereType<UserMessageItem>().single;
      expect(user.agentId, 'agt_a');
      expect(user.routingReason, 'create_new');
    });

    test('routingSelected 先到（乱序）→ 回退成独立提示行（单遍归约无法回头合并）', () {
      // 服务端把两个事件放进同一事务且 user_message 在前，加上控制器按
      // globalSeq 排序，生产不可达；这里钉的是纯函数的边界语义：先到的
      // 归属事件找不到气泡 → 按「孤儿事件」规则回退（新建类保留提示行）。
      final r = EventReducer.reduce([
        routing(reason: 'create_new', globalSeq: 1),
        userMsg(globalSeq: 2),
      ]);

      expect(r.items.whereType<UserMessageItem>(), hasLength(1));
      expect(r.items.whereType<RoutingNoticeItem>(), hasLength(1));
    });
  });

  group('孤儿 routing_selected（找不到用户气泡）', () {
    test('无聊原因：整条丢弃（不占一行）', () {
      final r = EventReducer.reduce([routing(reason: 'fixed_reuse')]);

      expect(r.items, isEmpty);
    });

    test('新建/切换/未知原因：回退成独立提示行（信息不丢）', () {
      for (final (reason, switched) in [
        ('create_new', false),
        ('fixed_reuse', true),
        ('weird_reason', false),
      ]) {
        final r = EventReducer.reduce([
          routing(reason: reason, switched: switched),
        ]);
        final notices = r.items.whereType<RoutingNoticeItem>().toList();
        expect(notices, hasLength(1), reason: reason);
        expect(notices.single.reason, reason);
      }
    });

    test('user_message 空文本被跳过时，其 turn 的归属回退成提示行', () {
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, id: 'evt_empty', payload: {'input': ''}),
        routing(reason: 'create_new'),
      ]);

      expect(r.items.whereType<UserMessageItem>(), isEmpty);
      expect(r.items.whereType<RoutingNoticeItem>(), hasLength(1));
    });
  });

  group('RoutingNoticeItem 渲染口径（现状兼容）', () {
    test('item 仍携带 turnId 与 groupId（回退行语义不变）', () {
      final r = EventReducer.reduce([
        routing(reason: 'create_new', id: 'evt_r1'),
      ]);

      final notice = r.items.whereType<RoutingNoticeItem>().single;
      expect(notice.id, 'evt_r1');
      expect(notice.turnId, 'turn_1');
      expect(notice.groupId, 'grp_9');
    });
  });
}

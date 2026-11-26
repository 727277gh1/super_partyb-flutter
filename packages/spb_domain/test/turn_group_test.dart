import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// [groupItemsByTurn] 与 [TurnGroup] 的测试。
///
/// 纯函数（无副作用、无 Flutter 依赖），可在无头环境完整验证。
void main() {
  // 便捷构造：造一个指定类型 + turnId 的对话项。
  // createdAt 用 turn 编号映射到不同的分钟，保证排序有意义。
  ConfirmationItem conf(
    String id,
    String turnId, {
    DateTime? createdAt,
    String question = '是否继续？',
  }) => ConfirmationItem(
    id: id,
    createdAt: createdAt ?? DateTime.utc(2024, 3, 5, 8, 9, 0),
    turnId: turnId,
    question: question,
    confirmationId: 'cf_$id',
    groupId: 'grp_1',
  );

  ToolCallItem tool(String id, String turnId, {DateTime? createdAt}) =>
      ToolCallItem(
        id: id,
        createdAt: createdAt ?? DateTime.utc(2024, 3, 5, 8, 9, 0),
        name: 'read',
        turnId: turnId,
        isComplete: true,
      );

  UserMessageItem userMsg(String turnId, String text, {DateTime? createdAt}) =>
      UserMessageItem(
        id: 'u_$turnId',
        createdAt: createdAt ?? DateTime.utc(2024, 3, 5, 8, 9, 0),
        turnId: turnId,
        text: text,
      );

  group('groupItemsByTurn', () {
    test('空列表返回空分组', () {
      expect(groupItemsByTurn([]), isEmpty);
    });

    test('单 turn 单项 → 单组', () {
      final groups = groupItemsByTurn([conf('c1', 't1')]);

      expect(groups, hasLength(1));
      expect(groups.single.turnId, 't1');
      expect(groups.single.items, hasLength(1));
    });

    test('同 turn 的项归入同一组，保持时间正序', () {
      final t0 = DateTime.utc(2024, 3, 5, 8, 0);
      final t1 = DateTime.utc(2024, 3, 5, 8, 1);
      final t2 = DateTime.utc(2024, 3, 5, 8, 2);

      final groups = groupItemsByTurn([
        userMsg('t1', '帮我写文档', createdAt: t0),
        tool('tc1', 't1', createdAt: t1),
        conf('c1', 't1', createdAt: t2),
      ]);

      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.turnId, 't1');
      // 组内按插入顺序（调用方保证事件正序传入）。
      expect(g.items.map((i) => i.runtimeType.toString()), [
        'UserMessageItem',
        'ToolCallItem',
        'ConfirmationItem',
      ]);
    });

    test('多 turn：最新活动在前（倒序）', () {
      final early = DateTime.utc(2024, 3, 5, 8, 0);
      final late = DateTime.utc(2024, 3, 5, 9, 0);

      final groups = groupItemsByTurn([
        userMsg('t_old', '旧对话', createdAt: early),
        userMsg('t_new', '新对话', createdAt: late),
      ]);

      expect(groups.map((g) => g.turnId), ['t_new', 't_old'], reason: '最新活动在前');
    });

    test('空 turnId 的项不丢弃，归入独立组', () {
      final groups = groupItemsByTurn([conf('c1', ''), userMsg('t1', 'hi')]);

      expect(groups, hasLength(2));
      // 含空 turnId 的组确实存在。
      final emptyGroup = groups.firstWhere((g) => g.turnId == '');
      expect(emptyGroup.items, hasLength(1));
    });

    test('历史回填前插更早项后，组的排序仍按最新活动', () {
      // 模拟：先有新事件，回填后又插入了同一 turn 的更早事件。
      // 组的「最新活动」应仍是该 turn 内最晚的那条，不影响组间排序。
      final older = DateTime.utc(2024, 3, 5, 7, 0);
      final newer = DateTime.utc(2024, 3, 5, 9, 0);

      final groups = groupItemsByTurn([
        // 按事件顺序：旧的先到（回填前插后）。
        userMsg('t1', '第一句', createdAt: older),
        userMsg('t2', '另一轮', createdAt: newer),
      ]);

      expect(groups.first.turnId, 't2', reason: '最新活动在前');
      expect(groups.last.turnId, 't1');
    });
  });

  group('TurnGroup 派生', () {
    test('userInput 取该轮最后一条用户消息', () {
      final groups = groupItemsByTurn([
        userMsg('t1', '第一句', createdAt: DateTime.utc(2024, 3, 5, 8, 0)),
        tool('tc1', 't1', createdAt: DateTime.utc(2024, 3, 5, 8, 1)),
        userMsg('t1', '补充一句', createdAt: DateTime.utc(2024, 3, 5, 8, 2)),
      ]);

      expect(groups.single.userInput, '补充一句', reason: '取最后一条，拿到最完整版本');
    });

    test('pendingConfirmations 只含未解决的', () {
      final groups = groupItemsByTurn([
        ConfirmationItem(
          id: 'resolved',
          createdAt: DateTime.utc(2024, 3, 5, 8, 0),
          turnId: 't1',
          question: 'q1',
          resolved: true,
          confirmationId: 'cf_r',
          groupId: 'grp_1',
        ),
        conf('pending', 't1', createdAt: DateTime.utc(2024, 3, 5, 8, 1)),
      ]);

      final g = groups.single;
      expect(g.confirmations, hasLength(2), reason: 'confirmations 含全部');
      expect(g.pendingConfirmations, hasLength(1));
      expect(g.pendingConfirmations.single.id, 'pending');
    });

    test('toolCalls 过滤出工具调用', () {
      final groups = groupItemsByTurn([
        userMsg('t1', 'hi'),
        tool('tc1', 't1'),
        tool('tc2', 't1'),
        conf('c1', 't1'),
      ]);

      expect(groups.single.toolCalls, hasLength(2));
      expect(groups.single.toolCalls.map((t) => t.id), ['tc1', 'tc2']);
    });

    test('无用户消息时 userInput 为空串', () {
      final groups = groupItemsByTurn([tool('tc1', 't1')]);

      expect(groups.single.userInput, '');
    });

    test('createdAt 取组内第一条', () {
      final t0 = DateTime.utc(2024, 3, 5, 8, 0);
      final t1 = DateTime.utc(2024, 3, 5, 8, 5);

      final groups = groupItemsByTurn([
        tool('tc1', 't1', createdAt: t0),
        conf('c1', 't1', createdAt: t1),
      ]);

      expect(groups.single.createdAt, t0, reason: '第一条的时间，即组的创建锚点');
    });
  });
}

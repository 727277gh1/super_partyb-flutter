import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

void main() {
  group('AgentChoice 三态', () {
    test('未选过（null）/ 显式自动 / 具体 agent 是三个不同取值', () {
      // ## 为什么这条是核心
      //
      // 「没有条目」与「显式选了自动」都**没有具体 agent**，若都表示成 null，
      // 重进对话时后者会被服务端绑定顶替 —— 下一条消息从 auto 悄悄变成
      // manual（用户选的自动路由失效），界面也改显示服务端那个人。
      final store = AgentChoiceStore();
      expect(store.choiceFor('grp_1'), isNull, reason: '未选过 = 没有条目');

      store.remember('grp_1', const AgentChoiceAuto());
      expect(store.choiceFor('grp_1'), const AgentChoiceAuto());
      expect(
        store.choiceFor('grp_1'),
        isNot(isA<AgentChoiceAgent>()),
        reason: '「自动」必须与「某个具体 agent」可区分',
      );
      expect(
        store.choiceFor('grp_1'),
        isNotNull,
        reason: '显式自动不得与被塌成 null（那会让重进对话时被服务端绑定顶替）',
      );
    });

    test('等值与 toString：相同 agent id 相等，不同 id 不等', () {
      const a = AgentChoiceAgent('agent_a');
      expect(a, const AgentChoiceAgent('agent_a'));
      expect(a == const AgentChoiceAgent('agent_b'), isFalse);
      expect(a.hashCode, const AgentChoiceAgent('agent_a').hashCode);
      expect(a.toString(), 'AgentChoice.agent(agent_a)');
      expect(const AgentChoiceAuto().toString(), 'AgentChoice.auto');
      expect(const AgentChoiceAuto(), const AgentChoiceAuto());
    });
  });

  group('AgentChoiceStore', () {
    test('按 group 隔离：一个对话的选择不影响另一个', () {
      final store = AgentChoiceStore()
        ..remember('grp_1', const AgentChoiceAuto())
        ..remember('grp_2', const AgentChoiceAgent('agent_b'));

      expect(store.choiceFor('grp_1'), const AgentChoiceAuto());
      expect(store.choiceFor('grp_2'), const AgentChoiceAgent('agent_b'));
      expect(store.choiceFor('grp_3'), isNull);
    });

    test('空 groupId 不入表也不命中（避免所有「没有 group」的调用共享脏条目）', () {
      final store = AgentChoiceStore()..remember('', const AgentChoiceAuto());
      expect(store.length, 0);
      expect(store.choiceFor(''), isNull);
    });

    test('forget 后回落「没选过」（即由服务端绑定兜底）', () {
      final store = AgentChoiceStore()
        ..remember('grp_1', const AgentChoiceAgent('agent_a'))
        ..forget('grp_1');
      expect(store.choiceFor('grp_1'), isNull);
    });

    test('超出容量淘汰最久未写的 group；重新写入会刷新次序', () {
      final store = AgentChoiceStore(capacity: 2)
        ..remember('grp_1', const AgentChoiceAuto())
        ..remember('grp_2', const AgentChoiceAuto());
      expect(store.length, 2);

      // 重新写 grp_1 = 最近用过 → 再来新人时应淘汰 grp_2 而不是 grp_1。
      store.remember('grp_1', const AgentChoiceAgent('agent_a'));
      store.remember('grp_3', const AgentChoiceAuto());

      expect(store.length, 2, reason: '容量是上限，不是预分配');
      expect(store.choiceFor('grp_1'), const AgentChoiceAgent('agent_a'));
      expect(store.choiceFor('grp_3'), const AgentChoiceAuto());
      expect(
        store.choiceFor('grp_2'),
        isNull,
        reason: '淘汰等价于「那个对话从没选过」→ 回落到服务端绑定',
      );
    });
  });
}

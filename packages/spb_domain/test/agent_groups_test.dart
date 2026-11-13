import 'package:test/test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// `groupAgents` / `filterAgentGroups` 的无头单测。
///
/// ## 这个测试防的是什么
///
/// 分组与过滤的**顺序**是用户能否找到 agent 的全部依据，而它在 widget 测试里
/// 只能靠「渲染出了几行」间接观察。排错了不会报错，只会让用户翻不到东西。
///
/// 生产实测（2026-10，bcc）：32 个 active agent、5 个分组（助手 14 / 营销 7 /
/// 1.助手 6 / 多媒体 4 / 文学 1）。本文件的样例数据按同一形状构造。
void main() {
  Agent agent(
    String id, {
    String name = '',
    String group = '',
    String description = '',
    List<String> tags = const [],
  }) => Agent(
    id: id,
    name: name,
    groupName: group,
    description: description,
    tags: tags,
  );

  group('groupAgents 分组', () {
    test('空列表返回空列表（不是「一个空的未分组组」）', () {
      expect(groupAgents(const []), isEmpty);
    });

    test('按 groupName 分组，组内保持入参顺序（服务端已按 name ASC）', () {
      final groups = groupAgents([
        agent('a1', name: '法务合规助手', group: '助手'),
        agent('a2', name: '财务记账助手', group: '助手'),
        agent('a3', name: '营销策略长', group: '营销'),
      ]);

      expect(groups.map((g) => g.name), ['助手', '营销']);
      expect(groups.first.agents.map((a) => a.id), [
        'a1',
        'a2',
      ], reason: '组内不重排——服务端 ListAgents 已按 name ASC 返回');
      expect(groups.last.agents.map((a) => a.id), ['a3']);
    });

    test('组间按组名 code-unit 升序（与用户手工排序意图一致）', () {
      // ⚠️ code-unit 序下「助手」在「营销」之前（佐 U+4F50 < 营 U+8425），
      // 与拼音序相反。这是**有意**的（Dart 无内置 locale 排序，见文件头），
      // 且生产数据里的分组名本就带数字前缀，码点序与用户手工排序一致。
      final groups = groupAgents([
        agent('a1', group: '营销'),
        agent('a2', group: '助手'),
        agent('a3', group: '1.助手'),
        agent('a4', group: '多媒体'),
      ]);

      expect(groups.map((g) => g.name), ['1.助手', '助手', '多媒体', '营销']);
    });

    test('空 groupName 归入「未分组」，且固定排在最后', () {
      final groups = groupAgents([
        agent('a1', group: ''),
        agent('a2', group: '助手'),
        agent('a3'),
      ]);

      expect(groups.map((g) => g.name), ['助手', ungroupedAgentLabel]);
      expect(groups.last.agents.map((a) => a.id), ['a1', 'a3']);
      expect(groups.last.isUngrouped, isTrue);
      expect(groups.first.isUngrouped, isFalse);
    });

    test('只有未分组时它仍是唯一一组（不因「排最后」而丢）', () {
      final groups = groupAgents([agent('a1'), agent('a2')]);

      expect(groups, hasLength(1));
      expect(groups.single.name, ungroupedAgentLabel);
      expect(groups.single.agents, hasLength(2));
    });

    test('groupName 前后空白被 trim（避免「助手」与「助手 」成为两个组）', () {
      final groups = groupAgents([
        agent('a1', group: '助手'),
        agent('a2', group: '  助手  '),
        agent('a3', group: '   '),
      ]);

      expect(groups.map((g) => g.name), ['助手', ungroupedAgentLabel]);
      expect(groups.first.agents.map((a) => a.id), ['a1', 'a2']);
    });

    test('toString 便于排障（含组名与数量）', () {
      expect(
        groupAgents([agent('a1', group: '助手')]).single.toString(),
        'AgentGroup(助手, 1 agents)',
      );
    });
  });

  group('agentMatchesQuery 单项匹配', () {
    final a = agent(
      'agent_legal',
      name: '法务合规助手',
      description: '合同审查与风险提示',
      tags: const ['legal', '合规'],
    );

    test('名称命中（子串）', () {
      expect(agentMatchesQuery(a, '法务'), isTrue);
      expect(agentMatchesQuery(a, '合规助手'), isTrue);
    });

    test('大小写不敏感（调用方无需先归一化）', () {
      expect(agentMatchesQuery(a, 'LEGAL'), isTrue);
      expect(agentMatchesQuery(a, 'Legal'), isTrue);
      // 前后空白也应被吃掉（用户从别处粘贴时常带空格）。
      expect(agentMatchesQuery(a, '  法务  '), isTrue);
    });

    test('id 命中（用户可能记得 id 片段）', () {
      expect(agentMatchesQuery(a, 'agent_leg'), isTrue);
    });

    test('description 命中（用户记得的是能力而不是名字）', () {
      expect(agentMatchesQuery(a, '合同'), isTrue);
      expect(agentMatchesQuery(a, '风险'), isTrue);
    });

    test('tags 命中', () {
      expect(agentMatchesQuery(a, '合规'), isTrue);
      expect(agentMatchesQuery(a, 'legal'), isTrue);
    });

    test('不命中返回 false', () {
      expect(agentMatchesQuery(a, '视频'), isFalse);
    });

    test('空查询恒命中（调用方无需特判）', () {
      expect(agentMatchesQuery(a, ''), isTrue);
    });

    test('名称为空时按 id 匹配（label 回退语义）', () {
      final unnamed = agent('agent_xyz');
      expect(unnamed.label, 'agent_xyz');
      expect(agentMatchesQuery(unnamed, 'xyz'), isTrue);
    });
  });

  group('filterAgentGroups 过滤', () {
    final groups = groupAgents([
      agent('a1', name: '法务合规助手', group: '助手', description: '合同审查'),
      agent('a2', name: '编程助手', group: '助手'),
      agent('a3', name: '营销策略长', group: '营销'),
      agent('a4', name: '小说创作', group: '文学'),
      agent('a5', name: '孤零零'),
    ]);

    test('空查询原样返回全部组', () {
      expect(filterAgentGroups(groups, ''), hasLength(groups.length));
      expect(filterAgentGroups(groups, '   '), hasLength(groups.length));
    });

    test('只保留命中的 agent，空组整个丢弃（不留空组头）', () {
      final out = filterAgentGroups(groups, '助手');

      // 「助手」既是组名（助手组）又命中 a1/a2 的名称，但组名命中优先整组保留。
      expect(out.map((g) => g.name), ['助手']);
      expect(out.single.agents.map((a) => a.id), ['a1', 'a2']);
    });

    test('组名命中 → 整组保留（用户想看的是那个组）', () {
      final out = filterAgentGroups(groups, '营销');

      expect(out.map((g) => g.name), ['营销']);
      expect(out.single.agents.map((a) => a.id), ['a3']);
    });

    test('description 命中也能找到（不必记得名字）', () {
      final out = filterAgentGroups(groups, '合同');

      expect(out.map((g) => g.name), ['助手']);
      expect(out.single.agents.map((a) => a.id), ['a1']);
    });

    test('无命中返回空列表', () {
      expect(filterAgentGroups(groups, '不存在的词'), isEmpty);
    });

    test('跨组命中时各组分别保留命中项，组顺序不变', () {
      // 「a」出现在 id a1..a5 里 → 每组都命中，组顺序应与 groupAgents 一致。
      final out = filterAgentGroups(groups, 'a');

      expect(out.map((g) => g.name), groups.map((g) => g.name));
    });

    test('过滤结果里的组是新的 AgentGroup（不与入参共享可变列表）', () {
      final out = filterAgentGroups(groups, '法务');

      expect(out.single, isNot(same(groups.first)));
      expect(out.single.agents, hasLength(1));
      // 入参未被修改（原组仍是 2 个）。
      expect(groups.first.agents, hasLength(2));
    });

    test('未分组桶也能被搜到（组名「未分组」或成员名）', () {
      final byGroupName = filterAgentGroups(groups, '未分组');
      expect(byGroupName.map((g) => g.name), [ungroupedAgentLabel]);

      final byMember = filterAgentGroups(groups, '孤零零');
      expect(byMember.map((g) => g.name), [ungroupedAgentLabel]);
      expect(byMember.single.agents.map((a) => a.id), ['a5']);
    });
  });
}

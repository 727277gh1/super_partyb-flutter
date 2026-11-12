/// Agent 列表的分组与搜索过滤（纯逻辑，可无头单测）。
///
/// ## 为什么在领域层而不是组件里
///
/// 「按组名分组、组间怎么排、搜索匹配哪些字段」是**正确性核心**：排错了用户
/// 就找不到 agent，而这类错误在 widget 测试里只能靠「渲染出了几行」间接观察。
/// 放在纯 Dart 层可以逐条断言顺序与匹配规则（与 `buildArtifactTree` 同一取向）。
///
/// ## 与 webapp 的两处**有意**差异
///
/// 1. **组间排序用 code-unit 比较**，不是 `localeCompare("zh-CN")`。Dart 标准库
///    无内置 locale 排序，为几个组名引 `intl` 不值当（与
///    `artifact_tree.dart` 的取舍逐字相同）。代价：中文组名落到 Unicode 码点序，
///    不符合拼音序——但**稳定且可复现**，且生产数据里的分组名本就带数字前缀
///    （`1.助手`），码点序与用户的手工排序意图一致。
/// 2. **[ungroupedAgentLabel] 固定排最后**，而不是像 webapp 那样把空组名当成
///    `"default"` 参与排序（那样它会因为拉丁字母排到最前）。理由：未分组是
///    「用户没归类」的**兜底桶**，不是用户主动创建的分类，排在最后才不干扰
///    用户自己的分组结构。
library;

import 'package:spb_models/spb_models.dart';

/// 未设置 `group_name` 的 agent 归入该分组（展示文案）。
///
/// ⚠️ 若用户真的建了一个叫「未分组」的分组，它会与兜底桶合并。这与 webapp 的
/// `"default"` 同型问题，可接受（否则要用一个不可能出现的哨兵字符串，而那会
/// 泄漏到 UI 文案里）。
const String ungroupedAgentLabel = '未分组';

/// 一个 agent 分组：组名 + 组内 agent（保持入参顺序）。
///
/// 组内**不重排**：服务端 `ListAgents` 已按 `name ASC` 返回（`agents.sql`），
/// 与 webapp 的 `groupAgentsByName` 一致——组内保持服务端顺序。
class AgentGroup {
  const AgentGroup({required this.name, required this.agents});

  /// 组名（`Agent.groupName`，空串已被归入 [ungroupedAgentLabel]）。
  final String name;

  final List<Agent> agents;

  /// 是否是「未分组」兜底桶（UI 可据此弱化组头样式）。
  bool get isUngrouped => name == ungroupedAgentLabel;

  @override
  String toString() => 'AgentGroup($name, ${agents.length} agents)';
}

/// 按 `Agent.groupName` 分组，组间按组名 code-unit 升序、未分组固定最后。
///
/// 空列表返回空列表（不是「一个未分组的空组」）——调用方据此决定是否渲染。
List<AgentGroup> groupAgents(Iterable<Agent> agents) {
  final buckets = <String, List<Agent>>{};
  for (final a in agents) {
    final raw = a.groupName.trim();
    final key = raw.isEmpty ? ungroupedAgentLabel : raw;
    (buckets[key] ??= <Agent>[]).add(a);
  }
  if (buckets.isEmpty) return const [];

  final names = buckets.keys.where((n) => n != ungroupedAgentLabel).toList()
    ..sort();
  // 未分组固定最后（见文件头「与 webapp 的差异」第 2 条）。
  if (buckets.containsKey(ungroupedAgentLabel)) {
    names.add(ungroupedAgentLabel);
  }
  return [for (final n in names) AgentGroup(name: n, agents: buckets[n]!)];
}

/// 按查询词过滤分组（大小写不敏感的子串匹配）。
///
/// ## 匹配范围
///
/// - **组名命中 → 整组保留**。用户搜「营销」时想看的是那个组，而不是逐个
///   agent 的 description 里有没有「营销」二字；
/// - 否则按 [agentMatchesQuery] 逐项过滤，空组整个丢弃（不留空组头）。
///
/// 空查询原样返回（同一实例），调用方无需特判。
List<AgentGroup> filterAgentGroups(Iterable<AgentGroup> groups, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return groups.toList();
  final out = <AgentGroup>[];
  for (final g in groups) {
    if (g.name.toLowerCase().contains(q)) {
      out.add(g);
      continue;
    }
    final matched = g.agents
        .where((a) => agentMatchesQuery(a, q))
        .toList(growable: false);
    if (matched.isNotEmpty) {
      out.add(AgentGroup(name: g.name, agents: matched));
    }
  }
  return out;
}

/// 单个 agent 是否命中查询词（大小写不敏感的子串匹配）。
///
/// [query] **任意大小写都可以**——函数内部自行 trim + 小写。不让调用方先归一化
/// 是因为那是纯粹的陷阱：忘了小写不会报错，只会让「搜 legal 有结果、搜 LEGAL
/// 没有」这种不一致悄悄出现（写这条用例时本人就踩了一次）。
///
/// 匹配 `label`（名称，空名回退 id）、`id`、`description`、`tags`。
///
/// ## 为什么也搜 description / tags
///
/// 用户记得的是**能力**而不是名字：「找那个能看合同的」可能既不记得它叫
/// 「法务合规助手」、也不知道 id。description 与 tags 正是这两类线索。
/// 代价是可能多命中几项——但结果按组展示、且用户能继续打字收窄，多命中
/// 远好于「搜不到」。
///
/// 不搜 `contentMd`：那是完整 prompt 正文，几千字，几乎任何词都能命中。
bool agentMatchesQuery(Agent agent, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (agent.label.toLowerCase().contains(q)) return true;
  if (agent.id.toLowerCase().contains(q)) return true;
  if (agent.description.toLowerCase().contains(q)) return true;
  return agent.tags.any((t) => t.toLowerCase().contains(q));
}

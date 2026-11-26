/// 「本对话接下来由谁回答」的**本地选择**（纯逻辑，无 IO、无 Flutter）。
///
/// ## 为什么需要它（三态）
///
/// 服务端只知道「当前绑定」（`group.active_session.agent_id`），它表达不出
/// 用户想要的是「让平台自动挑」。而客户端必须区分三件事：
///
/// | 状态 | 含义 | 下一条消息 |
/// |---|---|---|
/// | 没有条目（`null`） | 没选过 → 沿用服务端绑定 | 带绑定 id + `manual` |
/// | [AgentChoiceAuto] | 用户显式选了「自动路由」 | 不带 id + `auto` |
/// | [AgentChoiceAgent] | 用户选了具体某个 agent | 带该 id + `manual` |
///
/// 一个 `String?` 表达不了前两者（都是「没有具体 agent」）——把「自动」记成
/// `null` 会让「没选过」与「选了自动」塌成一个，重进对话时后者被服务端绑定
/// 顶替，下一条消息就悄悄从 `auto` 变成 `manual`（用户选的自动路由失效）。
/// 与 webapp `agentByGroup[groupId]` 的 `undefined | null | string` 三态同构。
///
/// ## 为什么存在**应用级**而不是页面 State 里
///
/// 见 [AgentChoiceStore] 的文档：webapp 的 `agentByGroup` 是应用级 map，离开
/// 会话再回来选择仍在；页面 State 里则随页面销毁而丢——那正是「选了『自动』，
/// 返回对话后 AppBar 又显示某个具体 agent」的原因。
library;

import 'package:meta/meta.dart';

/// 本地选择的一种取值（sealed：穷尽匹配，新增分支编译期即报错）。
sealed class AgentChoice {
  const AgentChoice();
}

/// 显式「自动路由」：把选择交回服务端 `auto_agent` 匹配。
final class AgentChoiceAuto extends AgentChoice {
  const AgentChoiceAuto();

  @override
  bool operator ==(Object other) => other is AgentChoiceAuto;

  @override
  int get hashCode => (AgentChoiceAuto).hashCode;

  @override
  String toString() => 'AgentChoice.auto';
}

/// 显式选中某个 agent。
final class AgentChoiceAgent extends AgentChoice {
  const AgentChoiceAgent(this.agentId);

  final String agentId;

  @override
  bool operator ==(Object other) =>
      other is AgentChoiceAgent && other.agentId == agentId;

  @override
  int get hashCode => agentId.hashCode;

  @override
  String toString() => 'AgentChoice.agent($agentId)';
}

/// `groupId → 本地 agent 选择` 的有界表（docs/memory-audit.md G3 同一取向）。
///
/// ## 为什么是应用级单例
///
/// 选择的语义是「**这个对话**接下来由谁回答」，它的生命周期与对话绑定，而
/// 不是与某一次页面实例绑定：
///
/// - 用户选了「自动路由」，返回列表再进来 → AppBar 仍应写「自动路由」，
///   且下一条消息仍按 `auto` 发出（webapp 的 `agentByGroup` 正是应用级）；
/// - 把它放在页面 State 里，返回后回落成服务端绑定值：界面显示某个具体
///   agent（与服务端绑定一致但**不是用户的选择**），且发送时带 `manual`
///   ——用户的「自动」被静默改成了「手动指定某人」。
///
/// ## 服务端绑定的角色：兜底而非权威
///
/// 没有本地条目时才读 `activeSession.agentId`（用户从未在本端选过）。这与
/// 既有语义一致：本地选择总是覆盖绑定，绑定只在没有选择时兜底。
///
/// ## 淘汰
///
/// 按「最久未写」淘汰（[remember] 会刷新次序）：单个条目只是「短 id → 一个
/// 小对象」，容量封顶后占用仍是个位数 KB。被淘汰等于「下次重进那个对话时
/// 回落到服务端绑定」——与从没选过同一效果，没有行为风险。
final class AgentChoiceStore {
  AgentChoiceStore({this.capacity = defaultCapacity});

  /// 默认容量：单次会话涉及的对话数量级（列表单页 50，跨页翻阅也不会到几百）。
  static const int defaultCapacity = 256;

  /// 条目上限；超出后淘汰最久未写的 group。**上限**而非预分配。
  final int capacity;

  /// `LinkedHashMap` 保写入序：`keys.first` 即最久未写。
  final Map<String, AgentChoice> _choices = {};

  /// 该对话的本地选择；没选过返回 null（调用方回落到服务端绑定）。
  ///
  /// 空 groupId 一律返回 null——正常路径不会出现（路由参数必有值），
  /// 但空串当键会让所有「没有 group」的调用共享一条脏条目。
  AgentChoice? choiceFor(String groupId) =>
      groupId.isEmpty ? null : _choices[groupId];

  /// 记下用户的选择（刷新该键的次序）。
  void remember(String groupId, AgentChoice choice) {
    if (groupId.isEmpty) return;
    // 先删再插：LinkedHashMap 的重复写入不改变次序，而这里要的是「最近用过」。
    _choices.remove(groupId);
    _choices[groupId] = choice;
    if (_choices.length > capacity) {
      _choices.remove(_choices.keys.first);
    }
  }

  /// 忘记该对话的选择（回落服务端绑定）。
  void forget(String groupId) => _choices.remove(groupId);

  /// 当前条目数（测试 / 诊断用）。
  @visibleForTesting
  int get length => _choices.length;
}

import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'agent_picker.dart';

/// 读取可选的 agent 列表（装配层注入 `AgentsApi.listAgents`）。
typedef LoadAgents = Future<List<Agent>> Function();

/// 选中某个 agent（**纯本地**，不发请求、不落库）。
///
/// 选中的语义是「本对话接下来由谁回答」：装配层把它记在本地，随**下一条消息**
/// 的 `agent_id` 发出，服务端在入队时归档旧绑定并重新绑定（见类文档）。
///
/// 传 `null` = 用户显式选了「自动路由」（把选择交回服务端 `auto_agent`）。
/// 注意这与「没选过」（未覆盖、沿用绑定）不是同一件事，装配层用三态区分
/// ——见两端 router 的 `_autoRouting`。
typedef SelectAgent = void Function(String? agentId);

/// 对话页 AppBar 的 agent 切换入口。
///
/// ## 语义：选择是**本地**的，服务端动作发生在下一条消息
///
/// 与 webapp 的 `AgentSelector` / `setAgentForGroup` 保持一致（那边是
/// `refactor(webapp): 选 Agent 改为纯本地，不再每次触发 /sessions/switch`）：
///
/// | 动作 | 客户端 | 服务端 |
/// |---|---|---|
/// | 点选 agent | 记本地（本组件只回调 [selectAgent]） | **什么都不发生** |
/// | 点「自动路由」 | 同上，回调 `selectAgent(null)` | **什么都不发生** |
/// | 发下一条消息 | 请求体带 `agent_id` | 入队事务里 `ReplaceBinding`：归档该 group 的旧 owner 绑定，写新绑定，**继承旧绑定的 `session_id`**（对话接着聊） |
///
/// 换 agent **不再断开上下文**（2026-11-06 服务端改为顶替归属、继承 session）：
/// `chatbinding.Ensure` 归档旧 owner 时把它的 `session_id` 写给新行，pigo 用
/// `-r` 续接同一段对话，只是人设换成新 agent（人设来自 group 工作区的
/// `AGENTS.md` 软链接，每轮重指）。
///
/// 因此**不弹确认框**：点选本身没有产生任何不可逆动作，弹窗只会变成每次切人
/// 都要点一下的形式主义。
///
/// ## 本组件**不**承担「清空上下文」
///
/// 那个动作（`force_new_session: true`）已搬到输入栏的
/// `MessageComposer.onNewSession`——本组件只做「选人」，菜单里不再有任何会发
/// 请求的项。理由：它是唯一不可逆的动作，需要确认框与完成提示，而菜单项只能
/// 「点了立刻执行」。详见 docs/design-decisions/chat.md §6.66。
///
/// ## 为什么列表为空 / 加载失败时**隐藏入口**
///
/// 与仓库其余可选注入同一取向（见 `SettingsPage` 的 `onOpenDirectory`）：
/// 展示一个点了没反应的入口比不展示更糟。失败时**不报错**也不弹提示——它是
/// AppBar 上的一个附属控件，为它弹一个错误横幅会打断用户当前在做的事。
/// 失败只记 `warn` 日志，便于排障。
///
/// 代价是：一次瞬时网络抖动会让入口在本页存活期间一直不出现。这是刻意的
/// ——重试逻辑会引入「加载中」状态，而 AppBar 上不该出现第二个转圈（停止
/// 按钮已占一个位置）。
///
/// ## 为什么小列表用 PopupMenu、大列表换成搜索弹层
///
/// 生产实测（2026-10，bcc）：**32 个 active agent / 5 个分组**
/// （助手 14 / 营销 7 / 1.助手 6 / 多媒体 4 / 文学 1）。
/// `PopupMenuButton` 的 `itemBuilder` 返回 `List<PopupMenuEntry>`，**塞不进
/// 输入框**——只能滚动着找。32 项 × 48dp ≈ 1650dp，用户要划好几屏，且没有
/// 任何分组结构。
///
/// 故按 [searchThreshold] 分档：
///
/// | 数量 | 载体 | 理由 |
/// |---|---|---|
/// | ≤ 8（一屏可见） | `PopupMenuButton` | 点两下就选中，搜索框反而是负担 |
/// | > 8 | 搜索弹层（[AgentPickerDialog]） | 打两个字收窄到 1 项 |
///
/// 弹层里**仍然分节展示**（按 `Agent.groupName`）：搜索是「找不到时」的手段，
/// 分组是「浏览时」的结构，两者不互相替代。分组/过滤的判据在 `spb_domain`
/// 的 `groupAgents` / `filterAgentGroups`（纯逻辑，可无头单测）。
///
/// 载体由本组件自己判断（`SpbEnv.isDesktop` 选 dialog / bottom sheet），
/// 故两端 router **一行都不用改**。
class AgentSwitcher extends StatefulWidget {
  const AgentSwitcher({
    super.key,
    required this.loadAgents,
    required this.selectAgent,
    this.currentAgentId,
    this.compact = false,
  });

  final LoadAgents loadAgents;

  /// 选中一个 agent（纯本地，见类文档）。
  final SelectAgent selectAgent;

  /// 「本对话当前由谁回答」的**有效**值——装配层传的是
  /// 「本地选择 ?? 服务端 active binding」（`ChatGroup.activeSession?.agentId`）。
  ///
  /// 为空 = 自动路由（`routing.mode=auto`，服务端按消息内容挑执行者），
  /// 标签显示「自动路由」——与 webapp `AgentSelector.tsx` 的
  /// `selectedName || t("autoRouting")`、小程序 `work-detail` 抽屉的
  /// `selectedAgentId: null` 同一语义。
  final String? currentAgentId;

  /// 紧凑模式：只显示图标，不显示 agent 名字。  ///
  /// ## 为什么需要它（issue #31）
  ///
  /// 标签最多占 140dp（名字长时），加图标与箭头后整个控件可达 190dp。窄屏
  /// AppBar 本就吃紧（issue #31 实测 320dp 下即使收起了三个低频入口，配上
  /// 长 agent 名仍溢出 10px）。
  ///
  /// ## 为什么省的是「名字」而不是整个入口
  ///
  /// 名字是**冗余信息**：`_currentLabel` 的内容在菜单里每一项旁边都有勾选
  /// 标记（`CheckedPopupMenuItem`），点开就能看到当前是哪个。而图标本身是
  /// 入口，省掉它用户就完全找不到切换处。
  ///
  /// 代价：用户要多点一下才知道当前 agent。这是窄屏下的合理取舍——320dp
  /// 的设备（如 iPhone SE 一代）本就无法同时容纳全部信息。
  final bool compact;

  /// 超过这个数量就换成搜索弹层（见类文档的表格）。
  ///
  /// 取 8 的依据：一屏 `PopupMenu` 在常见手机高度下能完整显示 6–8 项（含
  /// 菜单头与「自动路由」），超过它就要滚动，而滚动的列表里「找一项」与
  /// 「搜一项」的成本差距随长度线性放大。
  static const int searchThreshold = 8;

  @override
  State<AgentSwitcher> createState() => _AgentSwitcherState();
}

class _AgentSwitcherState extends State<AgentSwitcher> {
  List<Agent>? _agents;

  /// 是否已有一次加载在途。
  ///
  /// 用来把「失败后重试」限制成**每个 group 一次**。没有它，失败后 `_agents`
  /// 永远为 null，而父级每次 rebuild（SSE 事件、时间线更新、setState）都会
  /// 走进 `didUpdateWidget` → 再发一次请求，形成**请求风暴**：
  /// 实测在 `pumpAndSettle` 下留下大量未结算的 dio Timer，报
  /// 「A Timer is still pending even after the widget tree was disposed」。
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AgentSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅在**换了对话**（currentAgentId 真的变了）且上次没拿到列表时重试。
    //
    // 不用「每次 rebuild 都重试」：那会在持续失败时变成请求风暴（见 `_loading`
    // 的注释）。也不用「永不重试」：用户从加载失败的对话切到另一个对话时，
    // 应当再给一次机会。
    if (_agents == null && widget.currentAgentId != oldWidget.currentAgentId) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final agents = await widget.loadAgents();
      if (!mounted) return;
      setState(() => _agents = agents);
    } catch (e) {
      SpbLog.warn('读取 agent 列表失败，隐藏切换入口', {'error': e.toString()});
      // 刻意不 setState：保持 null 即「隐藏」，且不弹错误（见类文档）。
    } finally {
      _loading = false;
    }
  }

  /// 当前 agent 的展示名：优先用列表里的 name，缺失时回退 id。
  ///
  /// 回退 id 而非空串：显示空白会让用户不知道当前绑的是谁。
  String get _currentLabel {
    final id = widget.currentAgentId;
    if (id == null || id.isEmpty) return '自动路由';
    for (final a in _agents ?? const <Agent>[]) {
      if (a.id == id) return a.label;
    }
    return id;
  }

  /// 当前 agent 是否在可选列表里（不在 = 已归档/删除）。
  bool get _currentMissing {
    final id = widget.currentAgentId;
    if (id == null || id.isEmpty) return false;
    return !(_agents ?? const <Agent>[]).any((a) => a.id == id);
  }

  @override
  Widget build(BuildContext context) {
    final agents = _agents;
    // 未加载完 / 加载失败 / 没有可选项 → 不渲染（见类文档）。
    if (agents == null || agents.isEmpty) return const SizedBox.shrink();

    final trigger = _buildTrigger(context);

    // 小列表：保持原来的 PopupMenu（点两下就选中）。
    if (agents.length <= AgentSwitcher.searchThreshold) {
      return PopupMenuButton<AgentPick>(
        key: const ValueKey('agent-switcher'),
        tooltip: '切换 Agent',
        onSelected: _select,
        itemBuilder: (context) => _menuItems(context, groupAgents(agents)),
        child: trigger,
      );
    }

    // 大列表：换成搜索弹层（`itemBuilder` 塞不进输入框）。
    return InkWell(
      key: const ValueKey('agent-switcher'),
      borderRadius: SpbRadius.cardAll,
      onTap: _openPicker,
      child: trigger,
    );
  }

  Widget _buildTrigger(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.smart_toy_outlined, size: SpbSpacing.lg),
          const SizedBox(width: SpbSpacing.xs),
          if (!widget.compact)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                _currentLabel,
                key: const ValueKey('agent-switcher-label'),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
          // 当前 agent 已不在可选列表里（归档/删除）：给出标记，否则用户会
          // 疑惑「为什么这个 agent 在菜单里找不到」。
          if (_currentMissing)
            Tooltip(
              message: '当前 Agent 已不可用',
              child: Icon(
                Icons.warning_amber_outlined,
                size: SpbSpacing.lg,
                color: theme.colorScheme.error,
              ),
            ),
          const Icon(Icons.arrow_drop_down, size: SpbSpacing.lg),
        ],
      ),
    );
  }

  /// PopupMenu 的条目（按 [groupAgents] 分节）。
  List<PopupMenuEntry<AgentPick>> _menuItems(
    BuildContext context,
    List<AgentGroup> groups,
  ) {
    final theme = Theme.of(context);
    return [
      // 菜单头：说明「下一条消息」这个时机。它不再是「点一下就丢上下文」的
      // 警告（选择是纯本地的），但代价仍然真实存在，故保留一行说明。
      const PopupMenuItem<AgentPick>(
        enabled: false,
        height: 36,
        child: Text('选择后随下一条消息生效（沿用当前对话上下文）', style: TextStyle(fontSize: 12)),
      ),
      const PopupMenuDivider(),
      // 自动路由：**唯一**能把本地选择清回去的入口。选过某个 agent 之后
      // 服务端绑定不会自动回退，只有清成 null 才会让下一条消息重新走
      // `auto_agent` 匹配（webapp `AgentSelector.tsx` 的「自动路由（AI 选择）」
      // 首项、小程序 `work-detail` 抽屉的 null 项，语义一致）。
      CheckedPopupMenuItem<AgentPick>(
        key: const ValueKey('agent-option-auto'),
        value: const AgentPick.auto(),
        checked: widget.currentAgentId == null,
        // 已经是自动路由时不可选（同当前 agent 的置灰理由）。
        enabled: widget.currentAgentId != null,
        child: const Text('自动路由'),
      ),
      const PopupMenuDivider(),
      for (final g in groups) ...[
        // 组头：只在真的分组时出现。全是未分组时它只是噪音。
        if (g.name != ungroupedAgentLabel || groups.length > 1)
          PopupMenuItem<AgentPick>(
            key: ValueKey('agent-group-${g.name}'),
            enabled: false,
            height: 32,
            child: Text(
              g.name,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final a in g.agents)
          CheckedPopupMenuItem<AgentPick>(
            key: ValueKey('agent-option-${a.id}'),
            value: AgentPick.agent(a.id),
            checked: a.id == widget.currentAgentId,
            // 当前 agent **不可选**：选了也不会有任何变化（本地值没变、服务端
            // 也不收到请求），留着可点只会让用户怀疑「点了没反应」。
            // webapp 的 `AgentSelector.tsx` 用 `disabled={isCurrent}` 做了同一件事。
            enabled: a.id != widget.currentAgentId,
            child: Text(a.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      // 菜单只负责「选人」：本菜单**不再**包含任何会发请求的项。
      //
      // 「清空上下文」（旧名「同 Agent 开新会话」）已搬到输入栏
      // （`MessageComposer.onNewSession`，与 webapp 同位置）：那里可以弹确认框、
      // 可以在完成后提示，而菜单里的项只能「点了立刻执行」。两个入口两种行为
      // 是最难解释的不一致（docs/design-decisions/chat.md §6.66）。
    ];
  }

  /// 打开搜索弹层（大列表）。
  ///
  /// 桌面用 `showDialog`：鼠标操作不该从屏幕底部升起一个 sheet（那是移动端
  /// 的隐喻）。移动端用 `showModalBottomSheet`：与两端其余弹层载体一致
  /// （AGENTS.md §6.10）。
  Future<void> _openPicker() async {
    final agents = _agents;
    if (agents == null || agents.isEmpty) return;

    final picker = AgentPickerDialog(
      groups: groupAgents(agents),
      currentAgentId: widget.currentAgentId,
    );
    final pick = SpbEnv.isDesktop
        ? await showDialog<AgentPick>(
            context: context,
            builder: (dialogContext) => picker,
          )
        : await showModalBottomSheet<AgentPick>(
            context: context,
            isScrollControlled: true,
            builder: (sheetContext) => SafeArea(child: picker),
          );
    // null = 用户取消（`pop` 不传值）；`AgentPick` 本身才代表「选了什么」。
    if (pick == null || !mounted) return;
    _select(pick);
  }

  /// 选中：纯本地，不弹确认、不发请求（见类文档）。
  ///
  /// 与当前一致 = 无变化（`enabled: false` 已经挡了一层，这里兜住「外部重建
  /// 导致 currentAgentId 变化」的窗口）。
  void _select(AgentPick pick) {
    if (pick.agentId == widget.currentAgentId) return;
    widget.selectAgent(pick.agentId);
  }
}

// `_SwitcherAction` / `_SwitchTo` / `_NewSession` 已删：菜单现在只做「选人」，
// 直接以 [AgentPick] 作为 `PopupMenuButton` 的值类型（与搜索弹层共用同一个结果
// 类型）。不能用 `String?`：`PopupMenuButton` 把 `null` 结果当成「取消」，
// 而「自动路由」本身就是一个合法选择（见 agent_picker.dart 的 [AgentPick]）。

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
typedef SelectAgent = void Function(String agentId);

/// 同 Agent 开新会话（装配层调 `AgentsApi.switchGroupAgent`，`forceNewSession: true`）。
typedef StartNewSession = Future<void> Function();

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
/// | 发下一条消息 | 请求体带 `agent_id` | 入队事务里 `ReplaceBinding`：归档该 group 的旧 owner 绑定，写新绑定，`session_id` 留 NULL（lazy） |
/// | 点「同 Agent 开新会话」 | 调 `POST /chat/groups/:gid/sessions/switch`（`force_new_session: true`） | 立即归档 + 新绑定 |
///
/// 两种做法在**是否断开上下文**上等价（服务端 `chatbinding.Ensure` 对新 agent
/// 没有 active binding 时一律新开会话，pigo 首轮自产 session），差别只在时机与
/// 可见性：这里跟 webapp 一样把断开推迟到「下一条消息」，因此**不再弹确认框**
/// ——点选本身没有产生任何不可逆动作，弹窗只会变成每次切人都要点一下的形式主义。
///
/// 代价（明说）：上下文真正断开的那一刻用户看不到提示，只保留菜单顶部与搜索
/// 弹层顶部的那行说明。这是 webapp 既有的事实行为，客户端不做单方面的二次确认。
///
/// ## 为什么「同 Agent 开新会话」仍然调服务端
///
/// 这条动作没有「下一条消息」可以搭载——它要求**立刻**把旧绑定归档（会话的
/// 分界线就在这里），故必须走 `sessions/switch`。对应 webapp 输入栏的「新对话」
/// 按钮（`startNewConversation`）。同样不弹确认：入口文案本身已经写清它做什么。
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
    required this.startNewSession,
    this.currentAgentId,
    this.busy = false,
    this.compact = false,
  });

  final LoadAgents loadAgents;

  /// 选中一个 agent（纯本地，见类文档）。
  final SelectAgent selectAgent;

  /// 同 Agent 开新会话（立即归档旧绑定）。
  final StartNewSession startNewSession;

  /// 「本对话当前由谁回答」的**有效**值——装配层传的是
  /// 「本地选择 ?? 服务端 active binding」（`ChatGroup.activeSession?.agentId`）。
  ///
  /// 为空表示两端都没有：还没绑定（服务端懒激活或异常数据），此时仍展示入口，
  /// 标签显示「未绑定」，让用户能主动选一个。
  final String? currentAgentId;

  /// 开新会话是否在途（装配层传入）。为真时禁用入口，防重复触发。
  final bool busy;

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
  /// 菜单头与「开新会话」），超过它就要滚动，而滚动的列表里「找一项」与
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
    if (id == null || id.isEmpty) return '未绑定';
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
      return PopupMenuButton<_SwitcherAction>(
        key: const ValueKey('agent-switcher'),
        enabled: !widget.busy,
        tooltip: '切换 Agent',
        onSelected: _onSelected,
        itemBuilder: (context) => _menuItems(context, groupAgents(agents)),
        child: trigger,
      );
    }

    // 大列表：换成搜索弹层（`itemBuilder` 塞不进输入框）。
    return InkWell(
      key: const ValueKey('agent-switcher'),
      borderRadius: SpbRadius.cardAll,
      onTap: widget.busy ? null : _openPicker,
      child: Opacity(opacity: widget.busy ? 0.5 : 1, child: trigger),
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
  List<PopupMenuEntry<_SwitcherAction>> _menuItems(
    BuildContext context,
    List<AgentGroup> groups,
  ) {
    final theme = Theme.of(context);
    return [
      // 菜单头：说明「下一条消息」这个时机。它不再是「点一下就丢上下文」的
      // 警告（选择是纯本地的），但代价仍然真实存在，故保留一行说明。
      const PopupMenuItem<_SwitcherAction>(
        enabled: false,
        height: 36,
        child: Text('选择后随下一条消息生效（旧会话上下文会断开）', style: TextStyle(fontSize: 12)),
      ),
      const PopupMenuDivider(),
      for (final g in groups) ...[
        // 组头：只在真的分组时出现。全是未分组时它只是噪音。
        if (g.name != ungroupedAgentLabel || groups.length > 1)
          PopupMenuItem<_SwitcherAction>(
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
          CheckedPopupMenuItem<_SwitcherAction>(
            key: ValueKey('agent-option-${a.id}'),
            value: _SwitchTo(a.id),
            checked: a.id == widget.currentAgentId,
            // 当前 agent **不可选**：选了也不会有任何变化（本地值没变、服务端
            // 也不收到请求），留着可点只会让用户怀疑「点了没反应」。
            // webapp 的 `AgentSelector.tsx` 用 `disabled={isCurrent}` 做了同一件事。
            enabled: a.id != widget.currentAgentId,
            child: Text(a.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      // 同 agent 开新会话：单独一条，语义是「清空上下文但保留这个 agent」。
      // 与 webapp 输入栏的「新对话」按钮同义——它是唯一**立即**触发服务端
      // 动作的入口，因为它没有「下一条消息」可以搭载。
      if ((widget.currentAgentId ?? '').isNotEmpty) ...[
        const PopupMenuDivider(),
        const PopupMenuItem<_SwitcherAction>(
          key: ValueKey('agent-new-session'),
          value: _NewSession(),
          child: Text('同 Agent 开新会话'),
        ),
      ],
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
    final agentId = SpbEnv.isDesktop
        ? await showDialog<String>(
            context: context,
            builder: (dialogContext) => picker,
          )
        : await showModalBottomSheet<String>(
            context: context,
            isScrollControlled: true,
            builder: (sheetContext) => SafeArea(child: picker),
          );
    if (agentId == null || !mounted) return;
    await _onSelected(_SwitchTo(agentId));
  }

  Future<void> _onSelected(_SwitcherAction action) async {
    switch (action) {
      case _SwitchTo(:final agentId):
        // 与当前一致 = 无变化（`enabled: false` 已经挡了一层，这里兜住
        // 「外部重建导致 currentAgentId 变化」的窗口）。
        if (agentId == widget.currentAgentId) return;
        // 纯本地：不弹确认、不发请求（见类文档）。
        widget.selectAgent(agentId);
      case _NewSession():
        final agentId = widget.currentAgentId ?? '';
        if (agentId.isEmpty) return;
        // 吞掉异常只记日志：装配层（两端 router 的 `_startNewSession`）
        // **已经**弹过 SnackBar。不接住就会变成未捕获的异步异常，落到全局
        // 处理器（§6.24 的三道防线）——用户界面上看不到新信息，日志里多一条
        // 与已知失败重复的堆栈。
        //
        // 不能在此弹提示：`AgentSwitcher` 不知道失败原因该怎么描述（那是装配层
        // 的 `_describeSwitchError`），也不应该知道。
        try {
          await widget.startNewSession();
        } on Object catch (e) {
          SpbLog.debug('开新会话失败（装配层已提示）', {
            'agentId': agentId,
            'error': e.toString(),
          });
        }
    }
  }
}

/// 菜单项的动作（用 sealed 类而非裸字符串，避免 `agentId` 与哨兵值混淆）。
sealed class _SwitcherAction {
  const _SwitcherAction();
}

class _SwitchTo extends _SwitcherAction {
  const _SwitchTo(this.agentId);
  final String agentId;
}

class _NewSession extends _SwitcherAction {
  const _NewSession();
}

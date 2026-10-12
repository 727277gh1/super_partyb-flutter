import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 读取可选的 agent 列表（装配层注入 `AgentsApi.listAgents`）。
typedef LoadAgents = Future<List<Agent>> Function();

/// 把 group 切到另一个 agent（装配层注入 `AgentsApi.switchGroupAgent`）。
///
/// [forceNewSession] = 同 agent 开新会话（断开旧 session 上下文）。
typedef SwitchGroupAgent = Future<GroupAgentSwitchResult> Function(
  String agentId, {
  bool forceNewSession,
});

/// 对话页 AppBar 的 agent 切换入口。
///
/// ## 为什么必须有「历史上下文会断开」的确认
///
/// 服务端 `switchAgent`（`sessions.go`）先 `ArchiveChatGroupSessionsByGroup`
/// 归档该 group 的**全部**旧绑定，再写一条新 active binding。故切换 agent
/// 不是「换个签名接着聊」，而是**丢掉这段上下文**。
///
/// 这一点在 UI 上不可推断：用户看到的是同一个对话窗口、同一段历史消息（它们
/// 仍显示着），自然以为模型还记得。故切换前必须明确告知，而不是切完再说。
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
class AgentSwitcher extends StatefulWidget {
  const AgentSwitcher({
    super.key,
    required this.loadAgents,
    required this.switchAgent,
    this.currentAgentId,
    this.busy = false,
    this.compact = false,
  });

  final LoadAgents loadAgents;
  final SwitchGroupAgent switchAgent;

  /// 当前 group 的 active binding 指向的 agent id
  /// （`ChatGroup.activeSession?.agentId`）。
  ///
  /// 为空表示该 group 还没有绑定（服务端懒激活或异常数据）——此时仍展示入口，
  /// 标签显示「未绑定」，让用户能主动选一个。
  final String? currentAgentId;

  /// 切换是否在途（装配层传入）。为真时禁用入口，防并发切换把绑定打乱。
  final bool busy;

  /// 紧凑模式：只显示图标，不显示 agent 名字。
  ///
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

    final theme = Theme.of(context);
    return PopupMenuButton<_SwitcherAction>(
      key: const ValueKey('agent-switcher'),
      enabled: !widget.busy,
      tooltip: '切换 Agent',
      onSelected: _onSelected,
      itemBuilder: (context) => [
        // 菜单头：说明切换的代价。放在菜单里而非只在对话框里，是因为用户
        // 打开菜单时就要知道「这不是无损操作」。
        const PopupMenuItem<_SwitcherAction>(
          enabled: false,
          height: 36,
          child: Text('切换 Agent 会断开当前对话的上下文', style: TextStyle(fontSize: 12)),
        ),
        const PopupMenuDivider(),
        for (final a in agents)
          CheckedPopupMenuItem<_SwitcherAction>(
            key: ValueKey('agent-option-${a.id}'),
            value: _SwitchTo(a.id),
            checked: a.id == widget.currentAgentId,
            child: Text(a.label, overflow: TextOverflow.ellipsis),
          ),
        // 同 agent 开新会话：单独一条，语义是「清空上下文但保留这个 agent」。
        if ((widget.currentAgentId ?? '').isNotEmpty) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<_SwitcherAction>(
            key: ValueKey('agent-new-session'),
            value: _NewSession(),
            child: Text('同 Agent 开新会话'),
          ),
        ],
      ],
      child: Padding(
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
      ),
    );
  }

  Future<void> _onSelected(_SwitcherAction action) async {
    final (agentId, forceNewSession) = switch (action) {
      _SwitchTo(:final agentId) => (agentId, false),
      _NewSession() => (widget.currentAgentId ?? '', true),
    };
    if (agentId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('agent-switch-confirm'),
        title: Text(forceNewSession ? '开新会话？' : '切换 Agent？'),
        content: Text(
          forceNewSession
              ? '将以当前 Agent 开始一段新会话。\n\n'
                    '旧会话的上下文会断开——模型不再记得这段对话之前的内容。'
                    '历史消息仍会显示在这里。'
              : '将把本对话切换到「${_labelFor(agentId)}」。\n\n'
                    '旧绑定的上下文会断开——模型不再记得这段对话之前的内容。'
                    '历史消息仍会显示在这里。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('agent-switch-confirm-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.switchAgent(agentId, forceNewSession: forceNewSession);
  }

  String _labelFor(String agentId) {
    for (final a in _agents ?? const <Agent>[]) {
      if (a.id == agentId) return a.label;
    }
    return agentId;
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

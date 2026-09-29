import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'assistant_message_bubble.dart';
import 'confirmation_card.dart';
import 'follow_up_chips.dart';
import 'message_composer.dart';
import 'pending_messages_bar.dart';
import 'thought_tile.dart';
import 'tool_call_tile.dart';
import 'user_message_bubble.dart';

/// 对话页：时间线 + 输入框。
///
/// ## 数据来源
///
/// [controller] 的 `items` 流（归约后的 `List<ConversationItem>`）。页面**不做**
/// 任何归约/合并——那是 `spb_domain` 的职责，页面只负责渲染。
///
/// ## 自动滚到底
///
/// 新项到达时若用户**已在底部附近**则自动滚到底；若用户正在向上翻看历史
/// 则**不打扰**（否则滚动位置会被强制拽走，无法回看）。判定阈值见
/// [_autoScrollThreshold]。
///
/// 这是桌面 IM 的标准行为：无条件自动滚动会让「用户正在读历史时来一条新消息」
/// 变成一场与滚动的拔河。
class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.controller,
    this.title,
    this.onResolveConfirmation,
    this.onSend,
    this.loadPending,
    this.undoPending,
    this.pendingReloadKey,
    this.emptyHint = '还没有对话，输入消息开始吧',
  });

  final ChatStreamController controller;

  /// AppBar 标题。null 时不显示 AppBar。
  final String? title;

  /// 确认卡选项回调。参数为（group id, 卡行 id, 选项文案）。
  ///
  /// ## 为什么必须带 groupId（issue #1）
  ///
  /// 真实写端点是 `POST /api/chat/groups/:group_id/confirmations/:id/resolve`
  /// ——路径里必须有 group_id。只传 confirmationId 无法拼出该路径，
  /// 调用方只能报 404（且是静默的）。
  ///
  /// 为 null 时确认卡按钮禁用。
  final void Function(String groupId, String confirmationId, String option)?
  onResolveConfirmation;

  /// 自定义发送逻辑。为 null 时用 `controller.send(input: text)`。
  ///
  /// 之所以可覆盖：悬浮窗等入口走 `QuickCaptureUseCase`（无归属），
  /// 而本页是「已知 group」的常规发送。
  final Future<void> Function(String text)? onSend;

  /// 加载当前 group 的待处理收件箱消息。
  ///
  /// ## 为什么是「加载 + 撤销」两个回调，而不是收一个 `ChatApi`
  ///
  /// 撤销需要 **userId**（`POST /users/:uid/chat/messages/:id/undo`），而页面
  /// 不该知道 userId 从哪来（那要走 `/api/auth/me`，两端时机不同）。注入后
  /// 本页在 widget test 里可以完整验证（含 409 分支），不需要 HTTP mock。
  ///
  /// 为 null 时不展示待处理栏（保持「只读时间线」用法）。
  final LoadPendingMessages? loadPending;

  /// 撤销一条待处理消息（参数是 `ChatInboxMessage.id`，不是 turn id）。
  final UndoPendingMessage? undoPending;

  /// 变化时重新加载待处理消息（传 groupId）。
  ///
  /// 见 [PendingMessagesBar.reloadKey]：切换 group 时 State 会被复用，
  /// 不靠这个键就会一直显示上一个 group 的待处理消息。
  final String? pendingReloadKey;

  final String emptyHint;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _scrollController = ScrollController();

  /// 已提交 resolve 的卡行 id（本地去重，避免重复点击发出两次请求）。
  ///
  /// 服务端有 CAS（`pending` → `resolved` 首次写入才生效），重复请求不会造成
  /// 数据错误，但会让 UI 出现两次 loading。本地记录更简单直接。
  final _resolving = <String>{};

  /// 「算作在底部」的阈值（像素）。
  ///
  /// 不用 0：列表内容高度与视口高度在滚动过程中有细微抖动（图片解码、
  /// 字体加载），严格等于 maxScrollExtent 会导致自动滚动时断时续。
  static const double _autoScrollThreshold = 80;

  StreamSubscription<List<ConversationItem>>? _itemsSub;
  List<ConversationItem> _items = const [];

  /// 是否跟随底部。
  ///
  /// ## 为什么用状态标志而不是每次重新测量位置
  ///
  /// 直觉做法是在新项到达时测「当前位置是否在底部」。但**流式回复会在几十毫秒内
  /// 连续到达多个事件**，而自动滚动是 150ms 动画——上一次动画还在路上时，
  /// 新内容已把 maxScrollExtent 撞大，此时测量必然得到「不在底部」，
  /// 于是自动跟随**永久停掉**（用户没做任何操作，消息却不再跟随）。
  ///
  /// 用标志位：只在**滚动事件**里更新它（用户上滑 → false，回到接近底部 → true）。
  /// 新增内容本身不触发滚动事件，故不会误判。
  bool _following = true;

  @override
  void initState() {
    super.initState();
    _items = widget.controller.snapshot;
    _itemsSub = widget.controller.items.listen(_onItems);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ConversationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _itemsSub?.cancel();
      _items = widget.controller.snapshot;
      _itemsSub = widget.controller.items.listen(_onItems);
    }
  }

  @override
  void dispose() {
    _itemsSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onItems(List<ConversationItem> items) {
    setState(() => _items = items);

    if (_following) {
      // 等一帧：新项尚未布局完成，此时 maxScrollExtent 还是旧值。
      WidgetsBinding.instance.addPostFrameCallback((_) => _followBottom());
    }
  }

  /// 根据滚动位置更新 [_following]。
  ///
  /// 程序触发的滚动也会走到这里，但它向底部移动，结果是 `_following`
  /// 保持 true——正是期望的。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // 内容不足一屏时 maxScrollExtent == 0，视为在底部。
    if (position.maxScrollExtent <= 0) {
      _following = true;
      return;
    }
    _following =
        position.pixels >= position.maxScrollExtent - _autoScrollThreshold;

    // 跟随中仍未到底 → 继续追。
    //
    // ⚠️ 这一步不可省：`ListView.builder` 的 `maxScrollExtent` 是**惰性估算**的
    // ——它只根据已构建的可见项推算。新增内容后，估算值会在后续若干帧里逐步
    // 修正（实测：同一次推送后先报 321，几帧后才是真实的 1041）。
    // 若只在新增项时滚一次，滚动会停在中间（实测停 321/1041，约 1/3 处）。
    // 这里借「滚动会触发通知」这一点自我修正，直到真正到底。
    if (_following) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followBottom());
    }
  }

  /// 滚到底（仅在 [_following] 时由调用方触发）。
  void _followBottom() {
    if (!mounted || !_following || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = position.maxScrollExtent;
    // 已在底部就不动（避免无谓的滚动通知与重绘）。
    if ((position.pixels - target).abs() < 1) return;

    // 流式回复会在几十毫秒内连续到达多个事件，而滚动动画是 150ms。
    // 若每次都用 animateTo，新动画会**取消**上一个并从当前位置重来，
    // 永远追不上不断变大的 maxScrollExtent。故：
    //   - 距离较小时（单条新消息）用动画，视觉平滑；
    //   - 距离较大时（流式突发 / 惰性估算刚修正）直接 jump，保证一定到底。
    if (target - position.pixels > position.viewportDimension) {
      _scrollController.jumpTo(target);
      return;
    }
    _scrollController.animateTo(
      target,
      // 用令牌而非硬编码时长（见 docs/flutter-component-research.md §3.1）。
      duration: SpbDuration.fast,
      curve: Curves.easeOut,
    );
  }

  Future<void> _handleSubmit(String text) async {
    final custom = widget.onSend;
    if (custom != null) {
      await custom(text);
      return;
    }
    try {
      await widget.controller.send(input: text);
    } on SpbError catch (e) {
      // 发送失败：提示但不回滚输入（用户可能想重试同一段文字，
      // 清空反而让他重打一遍）。
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发送失败：${e.message}')));
    }
  }

  Future<void> _handleResolve(
    String groupId,
    String confirmationId,
    String option,
  ) async {
    final callback = widget.onResolveConfirmation;
    if (callback == null || _resolving.contains(confirmationId)) return;

    setState(() => _resolving.add(confirmationId));
    try {
      callback(groupId, confirmationId, option);
    } finally {
      if (mounted) setState(() => _resolving.remove(confirmationId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;

    return Scaffold(
      appBar: title == null
          ? null
          : AppBar(
              title: Text(title, overflow: TextOverflow.ellipsis),
              // 连接状态指示：SSE 断线时用户需要知道「不是没回复，是断了」。
              actions: [
                StreamBuilder<SseState>(
                  stream: widget.controller.connectionState,
                  initialData: widget.controller.currentState,
                  builder: (context, snapshot) =>
                      _ConnectionIndicator(state: snapshot.data),
                ),
                const SizedBox(width: SpbSpacing.sm),
              ],
            ),
      body: Column(
        children: [
          Expanded(
            child: _items.isEmpty
                ? _EmptyHint(text: widget.emptyHint)
                : _buildTimeline(),
          ),
          // 待处理消息栏紧贴输入框上方：它描述的是「我刚发出去、还没被处理
          // 的那条」，语义上与输入区相邻而非与时间线相邻。
          if (widget.loadPending != null && widget.undoPending != null)
            PendingMessagesBar(
              load: widget.loadPending!,
              undo: widget.undoPending!,
              reloadKey: widget.pendingReloadKey ?? '',
            ),
          MessageComposer(onSubmit: _handleSubmit),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    return ScrollConfiguration(
      // 桌面端：Flutter 默认的 dragDevices **不含鼠标**，不加这个
      // 鼠标拖拽无法滚动时间线（滚轮不受影响）。
      // 见 docs/flutter-component-research.md §3.1。
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: ListView.builder(
        controller: _scrollController,
        padding: SpbSpacing.pagePadding,
        // itemCount +1 给底部留白，避免最后一项紧贴输入框。
        itemCount: _items.length + 1,
        itemBuilder: (context, index) {
          if (index == _items.length) {
            return const SizedBox(height: SpbSpacing.xxl);
          }
          final item = _items[index];
          return Padding(
            // 稳定 Key：归约层保证 item.id 在同一逻辑项上不变，
            // Flutter 据此复用 Element，避免流式更新时整列重建。
            key: ValueKey(item.id),
            padding: const EdgeInsets.only(bottom: SpbSpacing.md),
            child: _buildItem(item),
          );
        },
      ),
    );
  }

  Widget _buildItem(ConversationItem item) => switch (item) {
    UserMessageItem(:final text) => UserMessageBubble(text: text),
    AssistantMessageItem(:final text, :final isStreaming) =>
      AssistantMessageBubble(text: text, isStreaming: isStreaming),
    ThoughtItem(:final text, :final isStreaming) => ThoughtTile(
      text: text,
      isStreaming: isStreaming,
    ),
    ToolCallItem(:final name, :final args, :final output, :final isComplete) =>
      ToolCallTile(
        name: name,
        args: args,
        output: output,
        isComplete: isComplete,
      ),
    ConfirmationItem() => ConfirmationCard(
      question: item.question,
      options: item.options,
      resolved: item.resolved,
      busy: _resolving.contains(item.confirmationId),
      // 用卡行 id 而非 item.id（事件 id）——见 ConfirmationItem.confirmationId。
      // 未携带 confirmation_id 的异常事件禁用按钮，不退化用事件 id 去试。
      onResolve: item.canResolve
          ? (option) => _handleResolve(
              item.groupId,
              item.confirmationId,
              option,
            )
          : null,
    ),
    FollowUpSuggestionItem(:final suggestions) => FollowUpChips(
      suggestions: suggestions,
      // 点 chip 即发送（与 webapp 一致）。走同一个 _handleSubmit，
      // 故 onSend 覆盖（如无归属入口）也会被尊重。
      onTap: _handleSubmit,
    ),
    RoutingNoticeItem(:final reason) => _RoutingNotice(reason: reason),
    ErrorItem(:final message) => _ErrorNotice(message: message),
  };
}

/// 连接状态指示（AppBar 右侧）。
class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.state});

  final SseState? state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String tooltip) = switch (state) {
      SseState.connected => (Icons.cloud_done_outlined, scheme.tertiary, '已连接'),
      SseState.connecting => (Icons.cloud_queue, scheme.primary, '连接中'),
      SseState.reconnecting => (Icons.cloud_off_outlined, scheme.error, '重连中…'),
      SseState.failed => (Icons.cloud_off, scheme.error, '连接失败'),
      SseState.idle || null => (Icons.cloud_outlined, scheme.outline, '未连接'),
    };

    return Tooltip(
      message: tooltip,
      child: Icon(icon, size: SpbSpacing.lg, color: color),
    );
  }
}

/// 归属判定提示。
class _RoutingNotice extends StatelessWidget {
  const _RoutingNotice({this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.center,
      child: Text(
        reason == null || reason!.isEmpty ? '已自动判定归属' : '归属：$reason',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 错误项。
class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Row(
          children: [
            Icon(Icons.error_outline, size: SpbSpacing.lg, color: scheme.error),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: SelectableText(
                message,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空列表提示。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

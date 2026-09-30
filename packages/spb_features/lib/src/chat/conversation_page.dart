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
    this.onCancelTurn,
    this.onLoadOlder,
    this.onReconnect,
    this.historyKey,
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

  /// 下载 agent 文件产物的回调。null 时下载按钮禁用。
  ///
  /// 页面不直接依赖 `spb_api`：真实下载（`UfsApi.download` + 落盘）由 app 层注入。
  final Future<void> Function(String turnId)? onCancelTurn;

  /// 向上翻页：加载更早的历史。
  ///
  /// 返回 `false` 表示「已到最早一条」，本页据此**停止**继续触发——否则每次滚动
  /// 到顶部都会发一个注定为空的请求（服务端游标 `global_seq < 0` 恒无结果）。
  ///
  /// 为 null 时不展示「加载更早」入口（保持「只读时间线」用法）。
  final Future<bool> Function()? onLoadOlder;

  /// 手动重连 SSE。
  ///
  /// ## 为什么需要它
  ///
  /// `SseClient` 自带指数退避重连，但退避到 `maxRetries` 后会把状态置为
  /// [SseState.failed] **永久停手**；而 `reconnecting` 期间遇到长退避时，用户
  /// 也可能不想等。两种情况下用户都需要一个「现在就再试一次」的入口。
  ///
  /// ## 为什么用注入而不是直接调 `controller.reconnect()`
  ///
  /// 与 [onCancelTurn] 同理：页面只收集意图，请求归调用方。页面已在用
  /// `controller` 读 items/连接状态，但重连是**动作**而非数据，注入后 widget
  /// test 里不需要真 SseClient 就能验证「什么状态下可点、点了几次」。
  ///
  /// 为 null 时指示器不可点（保持纯展示）。
  final VoidCallback? onReconnect;

  /// 当前对话的身份（两端都传 `groupId`）。
  ///
  /// ## 为什么必须显式传，而不能自己看出来
  ///
  /// 翻页终止标记（「已到最早一条」）的**有效范围是「一个对话」**，换了对话必须
  /// 重置。但本页无法自行察觉切换：SSE 是 user 级订阅，切 group 走的是
  /// `ChatStreamController.switchGroup`——**控制器实例不变**，`_ChatPage` 也未带
  /// `key`，故 State 被复用，`didUpdateWidget` 里 `oldWidget.controller ==
  /// widget.controller`。
  ///
  /// 不重置的后果：在 A 对话翻到头后切到 B，`_reachedOldest` 仍是 true，B 的
  /// 历史永远翻不出来（且毫无报错）。
  ///
  /// 不复用 [pendingReloadKey]：那个参数只在待处理栏接线时才存在，而翻页与它
  /// 无关——两者的值碰巧都是 groupId，但耦合会让「只接线待处理栏」的用法
  /// 静默带走翻页的正确性。
  final String? historyKey;

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

  /// 正在提交「停止生成」请求。
  ///
  /// ## 为什么需要它（而不是只看 isStreaming）
  ///
  /// 停止是一次往返请求，而服务端的 `done` 事件要等**下一轮**才会到达。这中间
  /// 的窗口里流式标记仍是 true，按钮会保持可点；用户再点一次会得到
  /// `409 turn not cancellable (not queued/running)`——一个从用户视角看毫无道理
  /// 的错误（他刚点了停止，界面却说不能停止）。用本地标记把窗口关掉。
  ///
  /// 不需要「请求失败就恢复」的特殊逻辑：finally 里无条件复位，若 `done` 已先
  /// 到达，复位后按钮依然禁用（因为流式项已被 `_sealStreaming` 闭合）。
  bool _cancelling = false;

  /// 是否已到最早一条历史（[ConversationPage.onLoadOlder] 返回过 false）。
  ///
  /// 一旦为 true 就不再触发，避免在顶部反复发空请求。
  bool _reachedOldest = false;

  /// 正在加载更早的历史（防止滚动过程中并发发多次请求）。
  bool _loadingOlder = false;

  /// 顶部触发阈值（像素）。
  ///
  /// 不用 0：`ListView` 的滚动位置在快速滑动时可能一瞬间就到 0，留一点余量
  /// 可以提前取下一页，让「滑到顶」与「内容已就位」重合而不是先看到空白。
  static const double _loadOlderThreshold = 120;

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
    // 换了对话就要重新给翻页一次机会：`_reachedOldest` 是上一个 group 的结论，
    // 沿用会让新对话永远翻不到历史（见 [historyKey] 的说明）。
    if (oldWidget.historyKey != widget.historyKey ||
        oldWidget.controller != widget.controller) {
      _reachedOldest = false;
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

    // 顶部触发加载更早历史。
    //
    // WHY 挂在滚动监听而不是另起 Timer / ScrollNotification：本页已有唯一的滚动
    // 监听（[_onScroll]），翻页与自动跟随共享同一个「位置已变」信号，不需要第二
    // 套时序。
    //
    // ⚠️ 必须放在下面「内容不足一屏」的 early return **之前**：那种情况下
    // `pixels == 0` 也正是「在顶部」，若在 early return 之后判断就会被跳过。
    // （实践中影响极小：首屏 `_backfill` 一次拉 200 条，短到填不满屏幕的对话
    // 基本意味着已全部加载。但把判断放在正确的位置不需要额外代价。）
    if (position.pixels <= _loadOlderThreshold) {
      unawaited(_maybeLoadOlder());
    }

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

  /// 到达顶部附近时加载更早的一页（带并发与终止保护）。
  ///
  /// 只在 [_onScroll] 里调用，而那里已确认 `_scrollController.hasClients`；
  /// 空列表时渲染的是 [_EmptyHint] 而非 `ListView`，控制器没有 client，
  /// 滚动通知根本不会产生。故这里不需要再判 `_items.isEmpty`。
  ///
  /// ## 已知边界：前插后不补偿滚动位置
  ///
  /// 向 `ListView` 头部插入内容会把当前可见内容整体下推（Flutter 保持
  /// `pixels` 不变），故翻页瞬间可视位置会跳到「新插入的那一页」。
  ///
  /// 正确的做法是记录插入前后的 `maxScrollExtent` 差值再补偿 `pixels`，但那需要
  /// 与自动跟随（[_following]）协调——两者同时生效时会把用户从顶部拽到底部。
  /// 本机无 DISPLAY、无法真机验证交互，靠猜写这段补偿只会得到一个「测试全绿但
  /// 手感不对」的实现，故先不做，待有桌面环境时按实测手感补上。
  Future<void> _maybeLoadOlder() async {
    final handler = widget.onLoadOlder;
    // 两重护栏：未注入 / 已到最早 / 正在加载。
    if (handler == null || _reachedOldest || _loadingOlder) return;

    _loadingOlder = true;
    try {
      final hasMore = await handler();
      if (!mounted) return;
      // 返回 false = 已到最早，从此不再触发。
      if (!hasMore) setState(() => _reachedOldest = true);
    } on SpbError catch (e) {
      // 失败不标记 `_reachedOldest`：下次滚到顶可以重试。
      if (mounted) _showMessage('加载更早历史失败：${e.message}');
    } finally {
      _loadingOlder = false;
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

  /// 当前仍在生成的项；null 表示没有进行中的生成。
  ///
  /// ## 为什么取「最后一个」而不是「任意一个」
  ///
  /// `items` 按时间升序，而 `done` 会闭合**全部**流式段落（`_sealStreaming`），
  /// 故同一时刻最多只有一个 turn 处于流式态。取最后一个与取任意一个等价，
  /// 但「最后一个」在将来若出现多段并存时，仍指向最新（也就是用户最想停的）那个。
  ///
  /// ## 为什么 [ThoughtItem] 也算
  ///
  /// 只认 [AssistantMessageItem] 会漏掉「agent 正在思考、还没吐第一个字」这段
  /// ——而那恰恰是最需要能停的时候（实测长 turn 的思考段可达数十秒）。两者都由
  /// 归约层在同一套 `isStreaming` 语义下维护：增量帧置 true，`done`/权威帧置 false。
  ConversationItem? get _streamingItem {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      final streaming = switch (item) {
        AssistantMessageItem(:final isStreaming) => isStreaming,
        ThoughtItem(:final isStreaming) => isStreaming,
        _ => false,
      };
      if (streaming) return item;
    }
    return null;
  }

  /// 停止当前轮次。
  Future<void> _handleCancelTurn() async {
    final handler = widget.onCancelTurn;
    // `turnId` 为空则不发请求：服务端路由是 `/chat/turns/:turn_id/cancel`，
    // 空 id 会打到 `/chat/turns//cancel`（语义不明的 404，见 issue #2 同源陷阱）。
    final turnId = _streamingItem?.turnId ?? '';
    if (handler == null || turnId.isEmpty || _cancelling) return;

    setState(() => _cancelling = true);
    try {
      await handler(turnId);
    } on SpbError catch (e) {
      // 失败只提示、不崩。**不**清空流式标记：turn 可能仍在跑，
      // 用户应当还能再试一次（而不是看着界面假装已停）。
      if (mounted) _showMessage('停止失败：${e.message}');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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

  /// 是否可以点「停止生成」。
  ///
  /// 两个条件：有流式项，且该项带着非空 [ConversationItem.turnId]。
  /// 后者不可省：`turnId` 为空说明事件未携带该字段（历史数据或异常载荷），
  /// 此时发不出正确的取消请求（见 [_handleCancelTurn]）。
  /// 提交中（[_cancelling]）同样禁用，避免连点。
  bool get _canCancelTurn {
    if (_cancelling) return false;
    final item = _streamingItem;
    return item != null && item.turnId.isNotEmpty;
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
                // 停止生成：仅在确有正在生成的轮次时可点。
                //
                // 选**禁用**而非隐藏：AppBar 宽度恒定，不会因状态切换而抖动；
                // 且用户能看到「这里有一个停止按钮，只是现在没什么可停」。
                if (widget.onCancelTurn != null) ...[
                  IconButton(
                    key: const ValueKey('conversation-cancel-turn'),
                    icon: const Icon(Icons.stop_circle_outlined),
                    tooltip: '停止生成',
                    onPressed: _canCancelTurn ? _handleCancelTurn : null,
                  ),
                  const SizedBox(width: SpbSpacing.xs),
                ],
                StreamBuilder<SseState>(
                  stream: widget.controller.connectionState,
                  initialData: widget.controller.currentState,
                  builder: (context, snapshot) => _ConnectionIndicator(
                    state: snapshot.data,
                    onReconnect: widget.onReconnect,
                  ),
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
          ), // 待处理消息栏紧贴输入框上方：它描述的是「我刚发出去、还没被处理
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
          ? (option) =>
                _handleResolve(item.groupId, item.confirmationId, option)
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
///
/// 非已连接态时变为可点的「重连」入口；已连接态是纯展示。
class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.state, this.onReconnect});

  final SseState? state;

  /// 手动重连回调。为 null（或已连接）时不可点。
  final VoidCallback? onReconnect;

  /// 是否渲染点击手势。
  ///
  /// ## 为什么已连接态必须**不渲染**手势，而不是渲染一个 `onTap: null`
  ///
  /// 指示器就在 AppBar 右侧、紧邻常用区域。已连接时它每秒都会重绘（心跳虽不进
  /// 业务流，但状态流会在重连时变动），一个仍然存在的 `InkWell` 会：
  /// 1. 在水波纹与 `Semantics` 上把图标宣告成「可点」，而它其实什么都不做；
  /// 2. 在触屏上把「误碰一下」变成一次无意义的重连（重连会 teardown 当前流，
  ///    正在传输的帧会被丢掉）。
  ///
  /// 故这里按状态换 widget 树，而不是给同一个树换个空回调。
  bool get _clickable => onReconnect != null && state != SseState.connected;

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

    // 内边距在两个分支下**相同**：否则可点/不可点切换时图标会左右移动
    // （与停止按钮选「禁用而非隐藏」同一个理由：AppBar 宽度必须恒定）。
    final iconWidget = Padding(
      padding: const EdgeInsets.all(SpbSpacing.sm),
      child: Icon(icon, size: SpbSpacing.lg, color: color),
    );

    return Tooltip(
      key: const ValueKey('conversation-connection-indicator'),
      message: _clickable ? '$tooltip（点击重连）' : tooltip,
      child: _clickable
          ? InkWell(
              onTap: onReconnect,
              customBorder: const CircleBorder(),
              child: iconWidget,
            )
          : iconWidget,
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

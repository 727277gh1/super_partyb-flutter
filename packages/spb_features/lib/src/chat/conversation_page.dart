import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'agent_file_card.dart';
import 'assistant_message_bubble.dart';
import 'confirmation_card.dart';
import 'feedback_request_card.dart';
import 'follow_up_chips.dart';
import 'message_composer.dart';
import 'spec_ui_card.dart';
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
    this.onResolveFeedback,
    this.onSpecAction,
    this.onSelectAgent,
    this.onSend,
    this.onFlush,
    this.onCancelTurn,
    this.onLoadOlder,
    this.onReconnect,
    this.onDownloadAgentFile,
    this.onOpenLink,
    this.historyKey,
    this.loadPending,
    this.undoPending,
    this.pendingReloadKey,
    this.activities,
    this.activitiesSnapshot,
    this.actions,
    this.emptyHint = '还没有对话，输入消息开始吧',
  });

  final ChatStreamController controller;

  /// AppBar 右侧追加的操作（不覆盖连接指示等内置项）。
  ///
  /// ## 为什么提供这个插槽而不要求调用方自建 Scaffold
  ///
  /// 桌面端要在 AppBar 放「交付物侧边栏开关」，但它不属于对话页的固有部件
  /// （移动端没有侧边栏）。提供一个**只在尾部追加**的插槽，移动端不传即可，
  /// 无需各平台自建一整套 Scaffold。
  final List<Widget>? actions;

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

  /// 归属反馈卡回调。参数为（回执 token, 是否准确）。
  ///
  /// 与 [onResolveConfirmation] 同理注入：真实写端点是
  /// `POST /chat/feedback/:token/resolve`，页面只收集意图，请求与错误翻译
  /// 归调用方（也使 widget test 无需 HTTP mock）。
  ///
  /// 为 null 时反馈卡按钮禁用。
  final void Function(String token, bool correct)? onResolveFeedback;

  /// spec 卡片上的动作回调（建议卡 `copy_text`、归属反馈卡 `send_next_input`）。
  ///
  /// 页面只上抛动作，由 app 层决定怎么处理（copy_text → 回填输入框、
  /// send_next_input → 直接发送），保持「页面不持有 ChatApi」的分层约定。
  final void Function(SpecUiAction action)? onSpecAction;

  /// 把选中 Agent 切到指定 id（建议卡标注了 agent_id 时）。
  ///
  /// 与 [onSpecAction] 分开：切 agent 是**本地 UI 状态**，不是网络动作，
  /// app 层只需 setState 即可，走同一回调会把两件事耦合。
  final void Function(String agentId)? onSelectAgent;

  /// 自定义发送逻辑。为 null 时用 `controller.send(input: text)`。
  ///
  /// 之所以可覆盖：悬浮窗等入口走 `QuickCaptureUseCase`（无归属），
  /// 而本页是「已知 group」的常规发送。
  final Future<void> Function(String text)? onSend;

  /// 「立即发送」：把服务端缓冲区里已 pending 的消息立即合并提交。
  ///
  /// null = 不显示该入口（如移动端或未接线时）。
  ///
  /// 与 [onSend] 的区别见 `MessageComposer` 的类文档：前者发**新的一条**，
  /// 本回调推**已经排队的那批**。
  final Future<void> Function()? onFlush;

  /// 下载 agent 文件产物的回调。null 时下载按钮禁用。
  ///
  /// 页面不直接依赖 `spb_api`：真实下载（`UfsApi.download` + 落盘）由 app 层注入。
  final Future<void> Function(AgentFileItem file)? onDownloadAgentFile;

  /// 打开 Markdown 回复里的链接。null 时链接不响应点击（仅保留样式）。
  ///
  /// 与 [onDownloadAgentFile] 同理：打开 URL 属平台 IO（Linux 走 `xdg-open`，
  /// 移动端走 `url_launcher`），页面只收集意图，由 app 层注入。
  final void Function(String url, String title)? onOpenLink;

  /// 停止正在生成的轮次（入参是 [ConversationItem.turnId]）。
  ///
  /// ## 为什么用注入而不是直接调 `ChatApi.cancelTurn`
  ///
  /// 与 [onResolveConfirmation] 同理：本页只收集意图（用户点了停止），请求与
  /// 错误翻译归调用方。页面不持有 `ChatApi`，故 widget test 里无需 HTTP mock
  /// 就能验证「什么条件下可点、点了传什么 turnId」。
  ///
  /// 为 null 时**不展示**停止按钮（保持「只读时间线」用法）。
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

  /// 执行中活动快照流（`turn_activity`，Transient）。
  ///
  /// ## 它解决什么问题
  ///
  /// 执行器在「已起跑但还没吐出任何正文」的空窗期是静默的（读代码、跑 bash、
  /// 等模型首 token），此时时间线不动，用户分不清「在干活」与「卡死了」。
  /// 本流携带「已运行多久 + 上一步是什么」，用于展示进度。
  ///
  /// ## 为什么是 Map 而不是单条快照
  ///
  /// SSE 是 user 级订阅，一条流里可能同时存在多个 turn 的活动。单条快照只能
  /// 表达「最近一次事件属于哪个 turn」，若那个 turn 不是当前流式的 turn，
  /// 页面就无法拿到自己需要的那条。Map 按 turnId 索引，直查即得。
  ///
  /// 为 null 时不展示活动指示（与 [activitiesSnapshot] 一同省略）。
  final Stream<Map<String, TurnActivitySnapshot>>? activities;

  /// 首帧活动快照（供首屏渲染，避免等下一次推送）。
  ///
  /// 与 [activities] 的关系同 `controller.snapshot` 与 `controller.items`：
  /// 快照是同步初值，流是后续增量。两者都要传，否则「事件在订阅前已到达」
  /// 会让指示器到下一次心跳（约 15s）才出现。
  final Map<String, TurnActivitySnapshot>? activitiesSnapshot;

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

  /// 已提交 resolveFeedback 的回执 token（防重复点击，与 [_resolving] 同理）。
  ///
  /// 服务端 CAS 保证重复请求无数据错误，但会让 UI 出现两次 loading。
  final _resolvingFeedback = <String>{};

  /// 追加到输入框的草稿通道（spec 卡 copy_text 动作的「回填输入框」路径）。
  ///
  /// 页面持有它并传给 [MessageComposer.draft]：spec 卡在**时间线里**，而输入框
  /// 在页面底部，两者是兄弟节点，没有更近的共同祖先可放状态。
  final _draft = ValueNotifier<String>('');

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

  /// `turn_activity` 订阅与最近一次快照（按 turnId 索引）。
  ///
  /// 与 [_items] 同取向：存在 State 里 + 订阅推送时 setState。若在 build 里
  /// 读 `controller.activitiesSnapshot`，那是同步 getter，建立不了依赖，
  /// 事件到达时**不会**触发重建（指示器永远不出现）。
  StreamSubscription<Map<String, TurnActivitySnapshot>>? _activitiesSub;
  Map<String, TurnActivitySnapshot> _activities = const {};

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
    _subscribeActivities();
  }

  /// 订阅活动流（仅在调用方传了 [ConversationPage.activities] 时）。
  ///
  /// 用「注入才订阅」而非「总是订阅 controller」：保持本页在未注入时是
  /// **纯只读时间线**（同 [ConversationPage.onCancelTurn] 等注入参数的取向），
  /// 且不白订阅一条无人消费的流。
  void _subscribeActivities() {
    final stream = widget.activities;
    if (stream == null) return;
    _activitiesSub = stream.listen((snapshot) {
      if (!mounted) return;
      setState(() => _activities = snapshot);
    });
    _activities = widget.activitiesSnapshot ?? const {};
  }

  @override
  void didUpdateWidget(ConversationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _itemsSub?.cancel();
      _items = widget.controller.snapshot;
      _itemsSub = widget.controller.items.listen(_onItems);
    }
    // 活动流换了来源（或从未注入变为注入）：重订阅。
    if (oldWidget.activities != widget.activities) {
      unawaited(_activitiesSub?.cancel());
      _activitiesSub = null;
      _activities = const {};
      _subscribeActivities();
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
    _activitiesSub?.cancel();
    _scrollController.dispose();
    _draft.dispose();
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

  /// 建议卡点按：把建议文本回填到输入框（copy_text 的 onAppend 路径）。
  ///
  /// 走 [_draft] 而非直接发送：MessageComposer 在页面底部，时间线里的卡片
  /// 无法直接访问它的 controller。
  void _handleSuggestionAppend(String text) {
    if (text.isEmpty) return;
    _draft.value = text;
  }

  /// spec 卡片上的动作上抛给 app 层。
  void _handleSpecAction(SpecUiAction action) {
    widget.onSpecAction?.call(action);
  }

  /// 提交归属反馈（防重复点击；与 [_handleResolve] 同构）。
  ///
  /// 解锁时机也一致：成功与失败都解锁——服务端 CAS 保证重复请求无数据错误，
  /// 失败时允许重试（不弹错误打断阅读）。
  Future<void> _handleResolveFeedback(String token, bool correct) async {
    final callback = widget.onResolveFeedback;
    if (callback == null || _resolvingFeedback.contains(token)) return;

    setState(() => _resolvingFeedback.add(token));
    try {
      callback(token, correct);
    } finally {
      if (mounted) setState(() => _resolvingFeedback.remove(token));
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

  /// 当前应展示的执行中活动快照；null 表示不该展示。
  ///
  /// ## 显示条件（逐条对齐 webapp `ChatMessageList.tsx:471`）
  ///
  /// | webapp 条件 | 本页等价物 |
  /// |---|---|
  /// | `turn.activity` 存在 | [_activities] 里有该 turnId 的快照 |
  /// | `isStreaming` | 该 turn 是 [_streamingItem] 的 turn |
  /// | `!hasAgentContent` | 该 turn 还没有非空正文的 [AssistantMessageItem] |
  /// | `!turn.status`（无终态） | 有流式项即意味着 `done` 尚未到达（`_sealStreaming` 会闭合全部流式段） |
  /// | `!turn.queueReason` | 客户端**未跟踪**排队原因（无对应领域字段），恒真 |
  ///
  /// ## 为什么四个条件都要
  ///
  /// 只判「有活动」会在两种情况下产生误导：
  /// 1. **已有正文**：正文在往下滚，再插一句「已运行 3 分」只是噪声；
  /// 2. **已收尾**：`done` 之后活动快照可能仍在 State 里（它是 Transient，
  ///    只能靠下一个事件或切对话清掉），不判终态会在完成的对话下挂一条
  ///    「执行中」，比不显示更糟。
  ///
  /// 反过来，这两个条件都不能用来「省掉 `isStreaming`」：`isStreaming` 才是
  /// 「turn 在跑」的直接证据，而「无正文」也可能是「早就跑完且本来就没回复」。
  TurnActivitySnapshot? get _visibleActivity {
    final streaming = _streamingItem;
    if (streaming == null || streaming.turnId.isEmpty) return null;

    final activity = _activities[streaming.turnId];
    if (activity == null) return null;

    // 已有正文 → 让位给真实内容。
    for (final item in _items) {
      if (item is AssistantMessageItem &&
          item.turnId == streaming.turnId &&
          item.text.isNotEmpty) {
        return null;
      }
    }
    return activity;
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
                // 调用方追加的操作（如桌面端的交付物侧边栏开关），
                // 放在连接指示**之前**：连接状态是全局性的，固定在最右侧。
                ...?widget.actions,
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
          // 执行中活动指示放在**时间线与待处理栏之间**：它描述的是「正在跑的
          // 那个 turn 的进度」，语义上属于时间线；而待处理栏的语义属于输入区，
          // 两者各贴各自的一端（见各自文档）。
          if (_visibleActivity != null)
            _TurnActivityIndicator(activity: _visibleActivity!),
          if (widget.loadPending != null && widget.undoPending != null)
            PendingMessagesBar(
              load: widget.loadPending!,
              undo: widget.undoPending!,
              reloadKey: widget.pendingReloadKey ?? '',
            ),
          MessageComposer(
            onSubmit: _handleSubmit,
            onFlush: widget.onFlush,
            draft: _draft,
          ),
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
      AssistantMessageBubble(
        text: text,
        isStreaming: isStreaming,
        onLinkTap: widget.onOpenLink,
      ),
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
    FollowUpSuggestionItem() => FollowUpChips(
      suggestions: item.suggestions,
      // 带 agent 标注的语义：点建议时先切 Agent（若标注了）再追加到输入框。
      //
      // 为什么从「点了直接发送」改为「回填输入框」：服务端给建议卡的动作就是
      // copy_text（「点击复制问题，可修改后再发送」），webapp 同样走
      // onAppend——建议是**追问的起点**，用户常要改几个字再发。直接发出去
      // 会把「我要改一下」变成「发错了再重来」。
      //
      // onSpecAction / onSelectAgent 都未注入时（旧调用方）退化为点击即发送。
      richSuggestions: [
        for (var i = 0; i < item.suggestions.length; i++)
          FollowUpSuggestion(
            text: item.suggestions[i],
            agentId: item.agentIdAt(i),
          ),
      ],
      onAppend: (widget.onSpecAction != null || widget.onSelectAgent != null)
          ? _handleSuggestionAppend
          : null,
      onSelectAgent: widget.onSelectAgent,
      onTap: _handleSubmit,
    ),
    GoalProgressItem() => SpecUiCard(
      doc: item.spec,
      // 进度卡里的按钮（goal_gate 的 spec 无动作，这里主要是向前兼容）。
      onAction: _handleSpecAction,
    ),
    RoutingNoticeItem(:final reason) => _RoutingNotice(reason: reason),
    ErrorItem(:final message) => _ErrorNotice(message: message),
    FeedbackRequestItem() => FeedbackRequestCard(
      question: item.question,
      options: item.options,
      resolved: item.resolved,
      busy: _resolvingFeedback.contains(item.token),
      // 三个条件都要满足才给可点按钮：
      //   - app 层注入了回执通道（未注入时点了没反应，不如直接禁用）；
      //   - token 非空（服务端按 token 直查请求，一次性 CAS，缺它必然失败）；
      //   - 尚未作答。
      onResolve: (widget.onResolveFeedback != null && item.canResolve)
          ? (correct) => _handleResolveFeedback(item.token, correct)
          : null,
    ),
    AgentFileItem() => AgentFileCard(
      file: item,
      onDownload: widget.onDownloadAgentFile,
    ),
  };
}

/// 执行中活动指示：在「已起跑但还没有正文」的空窗期展示「已运行 X · 最近：Y」。
///
/// ## 为什么需要它
///
/// 长 turn 的静默期可达数十秒（读代码 / 跑 bash / 等模型首 token）。此时时间线
/// 一动不动，用户唯一的判断依据是「它是不是死了」。本组件把服务端 `turn_activity`
/// 里的「已运行多久 + 上一步是什么」呈现出来，让等待有可见的进展。
///
/// ## 文案对齐 webapp
///
/// `apps/webapp/messages/zh.json`：
/// - `turnActivity` = `执行中 · 已运行 {elapsed}`
/// - `turnActivityJustStarted` = `刚开始`
/// - `turnActivityLast` = `最近：{action}`
///
/// 两者用同一套措辞，便于用户跨端对照。
class _TurnActivityIndicator extends StatelessWidget {
  const _TurnActivityIndicator({required this.activity});

  final TurnActivitySnapshot activity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final last = activity.lastEventType;

    return Material(
      key: const ValueKey('conversation-turn-activity'),
      // 与待处理栏同用 secondaryContainer：两者都是「临时状态条」，
      // 视觉上应属同一族而非各造一套。
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: SpbSpacing.lg,
              height: SpbSpacing.lg,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                '执行中 · 已运行 ${formatTurnElapsed(activity.elapsedMs)}',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            // 无上一步时不渲染该段：服务端首帧（刚起跑）不带 last_event_type，
            // 拼出「最近：null」比不显示更糟。
            if (last != null && last.isNotEmpty)
              Text(
                '最近：$last',
                key: const ValueKey('conversation-turn-activity-last'),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 已运行时长文案（毫秒 → 中文）。
///
/// ## 为什么在客户端算，而不是直接用服务端字符串
///
/// 服务端只给 `elapsed_ms`（数字），文案是渲染层职责。
///
/// ## 单位选择：≥ 1 分钟才拆成「X 分 Y 秒」
///
/// webapp 用 `date-fns` 的 `formatDuration({seconds}, {zero: false})`，实测输出
/// 是「3 秒」「90 秒」「7325 秒」——即**只取最大单位且不拆**（因为传进去的
/// duration 只有 `seconds` 字段）。本函数采用同一口径，但把 ≥ 60s 拆成
/// 「X 分 Y 秒」：
///
/// - `formatDuration` 在这种输入下给出的是「7325 秒」，人脑得自己除 60；
/// - 空窗期动辄几分钟，这是用户唯一的时间参照，「2 分 2 秒」比「122 秒」好读。
///
/// 这是**有意偏离**（改善可读性，不是修正错误）。若将来要求逐字对齐，改成
/// 「只取最大单位」即可，判定逻辑已在下方分开。
///
/// 负数与缺失一律按 0 处理（服务端异常载荷不产出「已运行 -1 秒」）。
@visibleForTesting
String formatTurnElapsed(int elapsedMs) {
  final totalSeconds = elapsedMs <= 0 ? 0 : (elapsedMs / 1000).round();
  if (totalSeconds < 60) return '$totalSeconds 秒';

  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (seconds == 0) return '$minutes 分钟';
  return '$minutes 分 $seconds 秒';
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

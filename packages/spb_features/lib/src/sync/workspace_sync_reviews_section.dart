import 'dart:async';

import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_ui/spb_ui.dart';

/// 拉取待确认同步项（跨 group 聚合）。null = 不展示本区块。
typedef LoadSyncReviewsAction = Future<WorkspaceSyncReviewsSnapshot> Function();

/// 处理一条待确认项（「同步」或「忽略」）。
typedef ResolveSyncReviewAction = Future<void> Function(
  WorkspaceSyncReviewEntry entry,
  WorkspaceSyncReviewAction action,
);

/// groupsync **待确认同步项**区块（设置页「交付物同步」标签内）。
///
/// ## 它解决的是什么
///
/// 服务端的文件同步 worker 在派发上传前会按目录/文件统计，命中上限就**不上传**
/// 并把集合挂起（单文件超 10 MiB、单目录超 500 个或 100 MiB、短时突增超 200 个，
/// 均可由部署覆盖）。挂起期间这些文件不进 UFS，**下行同步也永远拉不到**。
///
/// 用户的症状是「我让 agent 生成的报告没出现在交付物里」，而界面上原本没有任何
/// 东西解释这件事——本区块就是那个解释 + 处理入口（对齐 webapp 的
/// `WorkspaceSyncReviews`）。
///
/// ## 为什么不能只靠轮询
///
/// 服务端在「新挂起项出现」与「用户拍板完成」时会广播 `todo.changed`
/// （`Transient`，不落库、无 turn；真源仍是本区块的 GET）。此前唯一手段是
/// [pollInterval] 的 15 秒轮询——另一端停在待办页时最长要等 15 秒才看到新卡，
/// 而那段时间里用户以为「没有待办」。
///
/// 现在两条腿都留着：事件到达即重拉（省掉那段等待），事件丢了（断线、切后台）
/// 则回落轮询。**不得**把轮询删成「只靠事件」——`Transient` 不保证送达，
/// 服务端也明确写了「断线丢失只是晚一轮」。
///
/// ## 为什么不复用确认卡（`confirmation_required`）
///
/// 那是 agent 侧「要不要继续跑」的确认卡（`chat_confirmations` + SSE + 过期 TTL）。
/// 本区块是**文件同步 worker** 的挂起队列，端点、数据表、处理动作都不同，
/// 混用会让用户以为「确认继续」就能放行文件。
///
/// ## 空态就是**什么都不显示**
///
/// 没有待确认项时整块返回 [SizedBox.shrink]（与 webapp 一致）。理由：这是异常
/// 路径的解释，常态下占一块屏幕只会让「同步设置」页面变长，用户还得读一段
/// 永远不生效的说明。
class WorkspaceSyncReviewsSection extends StatefulWidget {
  const WorkspaceSyncReviewsSection({
    super.key,
    required this.load,
    required this.resolve,
    this.todoChanges,
    this.pollInterval = const Duration(seconds: 15),
    this.coalesceWindow = const Duration(milliseconds: 400),
  });

  /// 拉取聚合后的待确认项。
  final LoadSyncReviewsAction load;

  /// 处理一条（服务端拒绝时抛 [SpbError]）。
  final ResolveSyncReviewAction resolve;

  /// 轮询间隔。`Duration.zero` 表示不轮询（只在挂载时取一次）。
  ///
  /// 可缩短/关闭是为了无头测试：真实间隔下 widget test 要么等待 15 秒，
  /// 要么留下未完成的定时器。
  final Duration pollInterval;

  /// 待办失效通知流（`todo.changed`）。null = 只轮询（旧行为）。
  ///
  /// 由装配层接上 `ChatStreamController.todoChanges`（**必须**先
  /// `ensureConnected()`，否则流永远为空）。收到后只做一件事：重拉一次 GET。
  ///
  /// **不得**从事件推导列表或计数：载荷只有 `op` 是保证的，且它与后续真状态
  /// 可能不一致（服务端注释原话：payload 会丢，会与后续状态不一致）。
  ///
  /// ## 为什么是注入流而不是组件内自建订阅
  ///
  /// 组件不知道 SSE 从哪来、谁负责连接、登录态是否就绪。注入后本组件可在
  /// 无网络、无 Riverpod 的 widget test 里完整验证（与 `groupUpdates` 同一约定）。
  final Stream<TodoChange>? todoChanges;

  /// 连续多条事件合并成一个重拉窗口。
  ///
  /// 一次扫描拦下 N 个目录会发 N 条 `op=created`，逐条重拉会把失效通知退化成
  /// 突发请求（装配层一次重拉 = 1 次 group 列表 + 每个 group 一次 reviews）。
  ///
  /// `Duration.zero` 表示不合并（立即重拉），供测试使用。
  final Duration coalesceWindow;

  @override
  State<WorkspaceSyncReviewsSection> createState() =>
      _WorkspaceSyncReviewsSectionState();
}

class _WorkspaceSyncReviewsSectionState
    extends State<WorkspaceSyncReviewsSection> {
  WorkspaceSyncReviewsSnapshot? _snapshot;
  String? _error;
  Timer? _timer;

  /// 正在处理的那一条（挂起项 id）→ 按 id 禁用按钮，防重复点击。
  String? _busyId;

  /// 一次性结果提示（成功 / 已刷新）。
  String? _notice;

  /// 单飞：轮询与手动刷新可能同时触发，复用同一份在途 Future。
  Future<void>? _inFlight;

  /// `todo.changed` 订阅。
  ///
  /// 与轮询定时器**分开**维护：事件流是外部注入的，可能在 [didUpdateWidget]
  /// （登录态就绪、provider 重建）时被换掉，而定时器只跟 [pollInterval] 有关。
  StreamSubscription<TodoChange>? _todoSub;

  /// 合并窗口里已有待重拉（后面的同类事件直接被吃掉）。
  bool _coalescePending = false;
  Timer? _coalesceTimer;

  /// 列表展开上限（与 webapp 的 10 条一致）。
  int _visible = 10;

  static const int _pageSize = 10;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _startPolling();
    _subscribeTodoChanges();
  }

  @override
  void didUpdateWidget(WorkspaceSyncReviewsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 轮询间隔被换掉（或从「不轮询」改成有间隔）时重建定时器。
    if (oldWidget.pollInterval != widget.pollInterval) {
      _timer?.cancel();
      _timer = null;
      _startPolling();
    }
    // 事件流被换掉（userId 从 null 变成真值 → 占位空流换成真流）：重订阅。
    // 不重订阅的表现是「登录后本页拿到的仍是那个占位空流，事件永远不来」。
    if (!identical(oldWidget.todoChanges, widget.todoChanges)) {
      _subscribeTodoChanges();
    }
  }

  /// 重订阅 [WorkspaceSyncReviewsSection.todoChanges]。
  ///
  /// `unawaited(cancel())` 安全：broadcast 流的 cancel 同步生效，旧流不会再
  /// 回调本 State（回调里另有 [mounted] 护栏）。
  void _subscribeTodoChanges() {
    unawaited(_todoSub?.cancel());
    _todoSub = widget.todoChanges?.listen(_onTodoChange);
  }

  /// 收到一条「待办变了」通知：只做失效短路 + 合并重拉。
  ///
  /// 不碰任何状态：真正的列表仍由 [_refresh] 的 GET 决定。
  void _onTodoChange(TodoChange change) {
    if (!_todoChangeMatches(change)) return;
    if (widget.coalesceWindow <= Duration.zero) {
      unawaited(_refresh());
      return;
    }
    // 窗口内已有一次待重拉：新事件吃掉。列表是 GET 拿的，多刷一次没有意义；
    // 而且 [`_inFlight`] 的单飞只挡「同时在途」，不挡排队。
    if (_coalescePending) return;
    _coalescePending = true;
    _coalesceTimer = Timer(widget.coalesceWindow, () {
      _coalescePending = false;
      _coalesceTimer = null;
      if (!mounted) return;
      unawaited(_refresh());
    });
  }

  /// 这条通知是否可能改变本区块的快照。
  ///
  /// 1. 还没有快照（首屏未回填）→ 重拉：没有查询集可比；
  /// 2. 否则按**上一轮**的查询集判定（[TodoChange.matchesAnyGroup]：事件
  ///    groupId 缺失视为「不确定」→ 重拉）。
  ///
  /// ## 为什么可以跳过范围外的 group
  ///
  /// 本区块查的是「同步范围」里的一批对话，范围外的 group 即使待办变了，重拉
  /// 也不可能多出内容。⚠️ 但查询集是**上次查询**的范围、不是最新设置，故它只用来
  /// 省一次请求，**不得**当权限判据：范围刚改过时可能多等一轮轮询（15 秒），
  /// 下一次 [_refresh] 就会带上新范围。
  bool _todoChangeMatches(TodoChange change) {
    final snapshot = _snapshot;
    if (snapshot == null) return true;
    return change.matchesAnyGroup(snapshot.queriedGroupIds);
  }

  void _startPolling() {
    if (widget.pollInterval <= Duration.zero) return;
    _timer = Timer.periodic(widget.pollInterval, (_) {
      unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    unawaited(_todoSub?.cancel());
    _todoSub = null;
    super.dispose();
  }

  /// 拉取一份新快照。
  ///
  /// [silent] 为 true 时（轮询）失败**不清空**已有列表：一次网关抖动不该让
  /// 用户眼前那份「待确认项」凭空消失，否则他可能以为文件已经被处理了。
  Future<void> _refresh() {
    return _inFlight ??= () async {
      try {
        final snapshot = await widget.load();
        if (!mounted) return;
        setState(() {
          _snapshot = snapshot;
          _error = null;
          if (snapshot.entries.length < _visible) {
            _visible = snapshot.entries.length;
          }
        });
      } on SpbError catch (e) {
        if (!mounted) return;
        setState(() => _error = e.message);
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = '待确认项加载失败：$e');
      } finally {
        _inFlight = null;
      }
    }();
  }

  Future<void> _handleResolve(
    WorkspaceSyncReviewEntry entry,
    WorkspaceSyncReviewAction action,
  ) async {
    if (_busyId != null) return;
    setState(() {
      _busyId = entry.review.id;
      _notice = null;
      _error = null;
    });

    try {
      await widget.resolve(entry, action);
      if (!mounted) return;
      setState(() {
        _busyId = null;
        // 「同步」的文案**不能**说「已下载」：确认只是批准上传，文件还要等
        // worker 上传完 + 下一轮同步才下来（与回传侧的措辞同一理由）。
        // 「忽略」也不说「已删除」：服务端只是写进基线，文件仍在 workspace。
        _notice = action == WorkspaceSyncReviewAction.sync
            ? '已确认同步，文件会在下一轮同步后出现在本地'
            : '已忽略，这些文件不再提示（仍留在工作区）';
      });
    } on HttpError catch (e) {
      if (!mounted) return;
      if (e.isConflict) {
        // 409 = 这份快照已经变了（用户看列表期间 agent 又写了新文件）。
        // 重试同一份列表只会继续 409，故刷新后让用户按新的集合重新决定。
        setState(() {
          _busyId = null;
          _notice = '待处理项已变化，已刷新列表，请重新确认';
        });
      } else {
        setState(() {
          _busyId = null;
          _error = e.message;
        });
      }
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _busyId = null;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyId = null;
        _error = '处理失败：$e';
      });
    }
    // 失败分支**不刷新**：服务端状态没变（503 未启用 / 网络抖动），刷新只会
    // 用同样的列表盖掉刚设的 `_error`，用户看到的是一闪而过的错误。
    if (mounted && _error == null) await _refresh();
  }

  String _pathLabel(WorkspaceSyncReview review) =>
      // 服务端用 `.` 表示 workspace 根（目录级挂起最常见的情形：一次新增了
      // 几百个文件）。直接显示 `.` 会让用户以为是个错值。
      review.path.isEmpty || review.path == '.' ? '工作区根目录' : review.path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final snapshot = _snapshot;
    final entries = snapshot?.entries ?? const <WorkspaceSyncReviewEntry>[];

    // 加载失败且手里什么都没有 → 只给错误（带重试）。
    if (snapshot == null) {
      final error = _error;
      if (error == null) return const SizedBox.shrink();
      return ErrorBanner(
        key: const ValueKey('sync-reviews-error'),
        message: error,
        onRetry: () => unawaited(_refresh()),
      );
    }

    // 常态（含「服务端未启用 groupsync」与「没有待确认项」）：整块不显示。
    if (entries.isEmpty && _error == null && _notice == null) {
      return const SizedBox.shrink();
    }

    final shown = entries.take(_visible).toList(growable: false);

    return Card(
      key: const ValueKey('sync-reviews-card'),
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.pending_actions_outlined,
                  size: SpbSpacing.lg,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: SpbSpacing.sm),
                Expanded(
                  child: Text(
                    '待确认的同步项（${entries.length}）',
                    style: textTheme.titleSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('sync-reviews-refresh'),
                  onPressed: _busyId == null
                      ? () => unawaited(_refresh())
                      : null,
                  child: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: SpbSpacing.xs),
            Text(
              // 说清「为什么没同步」与「确认之后会发生什么」，否则用户只会看到
              // 一堆文件名与两个按钮。
              '这些文件因体积或数量超过服务端上限，被暂缓上传到云端，'
              '所以本地同步里看不到它们。确认后会重新上传，忽略则不再提示。',
              key: const ValueKey('sync-reviews-description'),
              style: SpbType.listMeta(textTheme)
                  ?.copyWith(color: scheme.onSecondaryContainer),
            ),
            if (snapshot.failedGroups > 0) ...[
              const SizedBox(height: SpbSpacing.xs),
              Text(
                // 如实说明覆盖不全：某些对话的待确认项这次没查到，别让用户以为
                // 「列表为空 = 没有待确认项」。
                '另有 ${snapshot.failedGroups} 个对话的待确认项查询失败，下次刷新会重试。',
                key: const ValueKey('sync-reviews-partial'),
                style: SpbType.listMeta(textTheme)
                    ?.copyWith(color: scheme.error),
              ),
            ],
            for (final entry in shown) ...[
              const SizedBox(height: SpbSpacing.sm),
              _ReviewItem(
                entry: entry,
                pathLabel: _pathLabel(entry.review),
                busy: _busyId == entry.review.id,
                disabled: _busyId != null && _busyId != entry.review.id,
                onResolve: (action) => unawaited(_handleResolve(entry, action)),
              ),
            ],
            if (entries.length > _visible) ...[
              const SizedBox(height: SpbSpacing.xs),
              TextButton(
                key: const ValueKey('sync-reviews-more'),
                onPressed: () => setState(() => _visible += _pageSize),
                child: Text('显示更多（还剩 ${entries.length - _visible}）'),
              ),
            ],
            if (_notice != null) ...[
              const SizedBox(height: SpbSpacing.sm),
              Text(
                _notice!,
                key: const ValueKey('sync-reviews-notice'),
                style: SpbType.listMeta(textTheme)
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: SpbSpacing.sm),
              Text(
                // 轮询失败时保留旧列表（见 _refresh），故错误只是一行附注。
                _error!,
                key: const ValueKey('sync-reviews-inline-error'),
                style: SpbType.listMeta(textTheme)
                    ?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单条待确认项。
class _ReviewItem extends StatelessWidget {
  const _ReviewItem({
    required this.entry,
    required this.pathLabel,
    required this.busy,
    required this.disabled,
    required this.onResolve,
  });

  final WorkspaceSyncReviewEntry entry;
  final String pathLabel;
  final bool busy;
  final bool disabled;
  final void Function(WorkspaceSyncReviewAction action) onResolve;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final review = entry.review;
    final id = review.id;

    return Column(
      key: ValueKey('sync-review-$id'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (entry.groupTitle.isNotEmpty)
          Text(
            entry.groupTitle,
            key: ValueKey('sync-review-group-$id'),
            // 层次靠字重不靠透明度（§6.78 规则 3，#127）：0.8 会把 12px
            // 压到 4.45:1，而同列相邻字段用的都是不透明原色。
            style: SpbType.listMeta(textTheme)?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        // SelectableText：路径可能很长且用户要复制去文件管理器/对话里核对。
        SelectableText(
          pathLabel,
          style: SpbType.body(textTheme)
              ?.copyWith(color: scheme.onSecondaryContainer),
        ),
        Text(
          review.reason.label,
          key: ValueKey('sync-review-reason-$id'),
          style: SpbType.listMeta(textTheme)
              ?.copyWith(color: scheme.onSecondaryContainer),
        ),
        Text(
          // 体积与数量同 webapp 口径（MiB 一位小数）：两端对同一份数据的描述
          // 必须一致，否则用户会以为看到的是两件事。
          '${review.fileCount} 个文件 · ${review.totalMegabytes} MiB',
          key: ValueKey('sync-review-summary-$id'),
          style: SpbType.listMeta(textTheme)
              ?.copyWith(color: scheme.onSecondaryContainer),
        ),
        if (review.directory)
          for (final sample in review.samples)
            Text(
              sample,
              // 0.7 透明度把 12px 降到 3.54:1（§6.78 规则 3，#127）。
              style: SpbType.listMeta(textTheme)
                  ?.copyWith(color: scheme.onSecondaryContainer),
            ),
        const SizedBox(height: SpbSpacing.xs),
        Row(
          children: [
            FilledButton.tonal(
              key: ValueKey('sync-review-sync-$id'),
              onPressed: busy || disabled
                  ? null
                  : () => onResolve(WorkspaceSyncReviewAction.sync),
              child: busy
                  ? const SizedBox(
                      width: SpbSpacing.md,
                      height: SpbSpacing.md,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('同步'),
            ),
            const SizedBox(width: SpbSpacing.sm),
            TextButton(
              key: ValueKey('sync-review-ignore-$id'),
              // 忽略是「不再提示」而非删除，故不做二次确认：服务端可逆的语义
              // （文件仍在工作区，只是写进基线）。真正不可逆的是「同步」覆盖
              // 远端，而那条路径的不可逆性由 worker 的上限阈值保护。
              onPressed: busy || disabled
                  ? null
                  : () => onResolve(WorkspaceSyncReviewAction.ignore),
              child: const Text('忽略'),
            ),
          ],
        ),
        const Divider(height: SpbSpacing.lg),
      ],
    );
  }
}

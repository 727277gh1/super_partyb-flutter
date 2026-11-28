import 'dart:async';

import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// 处理一条待确认同步项（「同步」或「忽略」）。
///
/// 服务端 409（`revision` 已变）由本组件识别为 `stale`，其余错误如实展示。
typedef ResolveSyncTodoAction = Future<void> Function(
  WorkspaceSyncReview review,
  WorkspaceSyncReviewAction action,
);

/// 待办面板里的「工作区待处理」区块（对齐 webapp 的 `WorkspaceSyncTodoSection`）。
///
/// ## 它解决什么
///
/// 交付物面板/设置页只回答「哪些文件被挂起了」，而用户真正会去找的是**待办**：
/// 「现在有什么在等我」。本区块把本对话被 groupsync 挂起的文件放进待办面板，
/// 与确认卡并列但**分区**呈现——两者的真源、动作、阻塞性都不同，混在一起会让
/// 用户以为「确认继续」就能放行文件（见 `docs/api-contract.md` §5）。
///
/// ## 纯展示 + 注入动作
///
/// 数据（[items]）与动作（[resolve]）全部由页面注入：取数、轮询、`todo.changed`
/// 失效都由装配层的 `SyncTodoFeed` 负责（徽标与面板必须共用同一份数据，而面板
/// 只在被切到的 tab 里才构建）。故本组件**不碰** SSE、不碰 Riverpod。
///
/// ## 注入方约定：没有东西可展示时传 null，而不是注入本组件
///
/// 本组件在「无待确认项 + 无错误 + 无提示」时渲染 `SizedBox.shrink()`，但宿主
/// `GroupTodosPanel` 只看「注入了没有」来决定要不要渲染「没有待处理的确认」占位
/// ——注入一个空区块会让待办面板整块空白（groupsync 开启且本对话无挂起文件时，
/// 那是最常见的状态）。装配层因此先判 `items.isEmpty && error == null` 再决定。
///
/// ## 409 不当失败
///
/// `revision` 是这批文件快照的 hash，用户看列表期间 agent 又写了文件 → 服务端
/// 409。此时重试同一份列表只会继续 409，故标 `stale` 并请页面立刻重拉，让用户
/// 按新集合重新决定（与设置页区块、webapp 同一判据）。
class WorkspaceSyncTodoSection extends StatefulWidget {
  const WorkspaceSyncTodoSection({
    super.key,
    required this.items,
    required this.resolve,
    this.turnLabels = const {},
    this.enabled = true,
    this.loading = false,
    this.error,
    this.onRetry,
    this.visibleLimit = 10,
  });

  /// 服务端挂起项（真源）。
  final List<WorkspaceSyncReview> items;

  /// 提交一次决定。
  final ResolveSyncTodoAction resolve;

  /// `turn_id → 轮次标题`（来自已加载的 turns）。查不到就退化为短 id，**不猜**。
  final Map<String, String> turnLabels;

  /// 服务端 groupsync 是否在跑。false 时整块不渲染。
  final bool enabled;

  /// 是否首屏加载中（此时 [items] 为空，不渲染「没有待办」）。
  final bool loading;

  /// 最近一次加载失败的原因（有值时展示错误行 + 重试）。
  final String? error;

  /// 请求重拉（错误行的「重试」与动作完成后的刷新都用它）。
  final Future<void> Function()? onRetry;

  /// 一次展示的上限（与设置页区块、webapp 一致）。
  final int visibleLimit;

  @override
  State<WorkspaceSyncTodoSection> createState() =>
      _WorkspaceSyncTodoSectionState();
}

class _WorkspaceSyncTodoSectionState extends State<WorkspaceSyncTodoSection> {
  /// 正在处理的那一条（`refId`）→ 禁用全部按钮，防重复点击。
  String? _busyRefId;

  /// 用户点过、但服务端说已变化的条目（`refId`）。
  final _staleRefIds = <String>{};

  /// 一次性结果提示（成功 / 已变化）。
  String? _notice;

  /// 动作失败的原因（与加载失败分开：前者要用户重试动作，后者重试取数）。
  String? _actionError;

  bool _visibleExpanded = false;

  @override
  void didUpdateWidget(WorkspaceSyncTodoSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表换了一批（group 切换 / 重新拉取）：已展开状态与一次性提示重置，
    // 否则会把上一个对话的「已确认同步」提示带到新对话上。
    if (oldWidget.items != widget.items) {
      _visibleExpanded = false;
    }
    if (oldWidget.enabled && !widget.enabled) {
      _notice = null;
      _actionError = null;
    }
  }

  Future<void> _handleResolve(
    WorkspaceSyncReview review,
    WorkspaceSyncReviewAction action,
  ) async {
    if (_busyRefId != null) return;
    final refId = syncTodoRefId(review);
    setState(() {
      _busyRefId = refId;
      _notice = null;
      _actionError = null;
    });

    try {
      await widget.resolve(review, action);
      if (!mounted) return;
      setState(() {
        _staleRefIds.remove(refId);
        // 与设置页区块同一措辞：「同步」不说「已下载」（确认只是批准上传），
        // 「忽略」不说「已删除」（服务端只写进基线，文件仍在工作区）。
        _notice = action == WorkspaceSyncReviewAction.sync
            ? '已确认同步，文件会在下一轮同步后出现在本地'
            : '已忽略，这些文件不再提示（仍留在工作区）';
      });
    } on HttpError catch (e) {
      if (!mounted) return;
      if (e.isConflict) {
        // 409 = 快照已变：标记 stale 并立刻重拉（不把 409 当成失败让用户重试）。
        setState(() {
          _staleRefIds.add(refId);
          _notice = '待处理项已变化，已刷新列表，请重新确认';
        });
      } else {
        setState(() => _actionError = e.message);
      }
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() => _actionError = e.message);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _actionError = '处理失败：$e');
    } finally {
      if (mounted) setState(() => _busyRefId = null);
    }

    // **无论成败都重拉**（与 webapp 一致）：真源只有 GET 这一个。
    // 失败时重拉不会盖掉错误——错误是本组件的 `_actionError`，刷新只换列表；
    // 反过来，失败后不刷新会让用户在别处（另一台设备 / 设置页）已经处理掉的
    // 条目继续挂在面板上，直到下一轮 15 秒轮询才消失。
    if (mounted) await widget.onRetry?.call();
  }

  String _pathLabel(WorkspaceSyncReview review) =>
      // 服务端用 `.` 表示 workspace 根（目录级挂起最常见的情形）。
      review.path.isEmpty || review.path == '.' ? '工作区根目录' : review.path;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();

    final todos = buildWorkspaceSyncTodos(
      widget.items,
      staleRefIds: _staleRefIds,
    );
    // 空态就是**什么都不显示**（与设置页区块、webapp 一致）：这是异常路径的
    // 解释，常态下占一块屏幕只会让待办面板变长。
    if (todos.isEmpty &&
        widget.error == null &&
        _actionError == null &&
        _notice == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = _visibleExpanded
        ? todos
        : todos.take(widget.visibleLimit).toList(growable: false);
    final hidden = todos.length - shown.length;

    return Card(
      key: const ValueKey('sync-todo-section'),
      margin: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xs,
      ),
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(SpbSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.sync_problem_outlined,
                  size: SpbSpacing.lg,
                  color: scheme.primary,
                ),
                const SizedBox(width: SpbSpacing.xs),
                Expanded(
                  child: Text(
                    todos.isEmpty ? '工作区待处理' : '工作区待处理（${todos.length}）',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (todos.isNotEmpty) ...[
              const SizedBox(height: SpbSpacing.xs),
              Text(
                '这些文件超过同步上限，已被服务端挂起——不确认就不会上传，'
                '下行同步也拉不到它们。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            for (final todo in shown) _todoCard(context, todo),
            if (hidden > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('sync-todo-more'),
                  onPressed: () => setState(() => _visibleExpanded = true),
                  child: Text('显示更多（还有 $hidden 条）'),
                ),
              ),
            if (widget.error != null || _actionError != null) ...[
              const SizedBox(height: SpbSpacing.xs),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _actionError ?? widget.error!,
                      key: const ValueKey('sync-todo-error'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                  if (widget.onRetry != null)
                    TextButton(
                      onPressed: () {
                        setState(() => _actionError = null);
                        unawaited(widget.onRetry!());
                      },
                      child: const Text('重试'),
                    ),
                ],
              ),
            ],
            if (_notice != null) ...[
              const SizedBox(height: SpbSpacing.xs),
              Text(
                _notice!,
                key: const ValueKey('sync-todo-notice'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _todoCard(BuildContext context, WorkspaceSyncTodoItem todo) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final review = todo.review;
    final busy = _busyRefId == todo.refId;
    final stale = todo.state == SyncTodoItemState.stale;
    final attribution = describeSyncTodoAttribution(
      review.turnId,
      widget.turnLabels,
    );

    return Card(
      key: ValueKey<String>('sync-todo-${todo.refId}'),
      margin: const EdgeInsets.only(top: SpbSpacing.xs),
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(SpbSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_pathLabel(review), style: theme.textTheme.labelLarge),
            const SizedBox(height: 2),
            Text(
              '${review.reason.label} · ${review.fileCount} 个文件 · '
              '${review.totalMegabytes} MiB',
              style: SpbType.listMeta(theme.textTheme)
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            // 目录级挂起时列出样本文件名：用户要知道「是哪几个文件」才能决定。
            for (final sample
                in review.directory ? review.samples : const <String>[])
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  sample,
                  style: SpbType.listMeta(theme.textTheme)
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            if (attribution != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  attribution.kind == SyncTodoAttributionKind.title
                      ? '来自「${attribution.text}」'
                      : '来自轮次 ${attribution.text}',
                  style: SpbType.listMeta(theme.textTheme)
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            if (stale)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '这条已变化，请按最新列表重新确认',
                  key: ValueKey<String>('sync-todo-stale-${todo.refId}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.tertiary,
                  ),
                ),
              ),
            const SizedBox(height: SpbSpacing.xs),
            Wrap(
              spacing: SpbSpacing.xs,
              children: [
                FilledButton.tonal(
                  key: ValueKey<String>('sync-todo-sync-${todo.refId}'),
                  onPressed: _busyRefId != null
                      ? null
                      : () => _handleResolve(
                          review,
                          WorkspaceSyncReviewAction.sync,
                        ),
                  child: Text(
                    busy
                        ? '处理中…'
                        : review.directory
                        ? '同步这个目录'
                        : '同步这个文件',
                  ),
                ),
                TextButton(
                  key: ValueKey<String>('sync-todo-ignore-${todo.refId}'),
                  onPressed: _busyRefId != null
                      ? null
                      : () => _handleResolve(
                          review,
                          WorkspaceSyncReviewAction.ignore,
                        ),
                  child: const Text('忽略'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

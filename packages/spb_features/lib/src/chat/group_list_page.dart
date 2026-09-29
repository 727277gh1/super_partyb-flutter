import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

import 'group_management.dart';

/// 对话列表页（offset 分页）。
///
/// ## 分页约定：offset 而非游标
///
/// `GET /chat/groups` 用 `?limit=&offset=`（与 timeline 的
/// `before_global_seq` 游标**不同**——两套约定并存是既有事实，见 AGENTS.md §5.7）。
///
/// 用 offset 分页时「加载更多」必须**去重**：offset 分页在列表变动时会产生
/// 重复项（服务端在两次请求之间新增/删除对话会移动窗口）。故 [_loadMore] 按
/// [ChatGroup.id] 去重，否则 Flutter 的列表会出现重复 Key 崩溃。
///
/// ## 滚动触发加载
///
/// 不用「加载更多」按钮：桌面端滚到底是自然动作，加按钮反而多一步。
/// 用 [ScrollController] 监听接近底部时预加载（提前一屏），避免用户看到白屏等待。
class GroupListPage extends StatefulWidget {
  const GroupListPage({
    super.key,
    required this.api,
    this.onOpenGroup,
    this.onGroupAction,
    this.onSearch,
    this.onOpenWorks,
    this.pageSize = 30,
  });

  final ChatApi api;

  /// 点击某个对话时的回调。
  final void Function(ChatGroup group)? onOpenGroup;

  /// 执行管理动作（改名/归档/取消归档/删除）。
  ///
  /// ## 为什么页面不自己调 `ChatApi`
  ///
  /// 本页只做**渲染与交互**（见 `chat.dart` 的分层说明）。动作的执行、错误
  /// 翻译、以及「删除后要不要跳走」这类决策都属于调用方。页面只负责：收集
  /// 用户意图（菜单 + 对话框）→ 交给回调 → 按返回的权威结果更新本地列表。
  ///
  /// 返回 [GroupActionRejected] 表示服务端明确拒绝（页面提示原因）；
  /// 抛出异常表示网络/解析失败（页面同样提示）。
  ///
  /// 为 null 时**不展示任何管理入口**（保持「只读列表」用法，如首页预览）。
  final Future<GroupActionResult> Function(ChatGroup group, GroupAction action)?
  onGroupAction;

  /// 打开搜索页。
  ///
  /// 为 null 时**不展示**搜索按钮——入口存在但点了没反应比没有入口更糟。
  /// 页面不做路由，由调用方决定跳转方式（同 [onOpenGroup]）。
  final VoidCallback? onSearch;

  /// 打开工作台（小程序 BFF 的工作列表）。
  ///
  /// 为 null 时**不展示**入口。仅移动端接线——桌面端不做小程序投影层
  /// （那是为小程序/移动端准备的 BFF）。
  final VoidCallback? onOpenWorks;

  final int pageSize;

  @override
  State<GroupListPage> createState() => _GroupListPageState();
}

class _GroupListPageState extends State<GroupListPage> {
  final _scrollController = ScrollController();
  final _groups = <ChatGroup>[];

  /// 已见过的 id，用于 offset 分页去重（见类文档）。
  final _seenIds = <String>{};

  bool _loading = false;
  bool _hasMore = true;
  SpbError? _error;

  /// 正在执行管理动作的 group id。
  ///
  /// ## 为什么需要它
  ///
  /// 改名/删除是**往返请求**。期间若用户再次点菜单，会发出第二个请求——
  /// 对删除尤其危险（第二次会得到 404 并提示「失败」，而实际第一次已成功，
  /// 用户会以为没删掉）。这里把对应条目的菜单禁用掉。
  String? _busyGroupId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // 提前一屏触发：用户滚到底时数据已经在路上了。
    if (position.pixels >=
        position.maxScrollExtent - position.viewportDimension) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final page = await widget.api.listGroups(
        limit: widget.pageSize,
        offset: _groups.length,
      );
      if (!mounted) return;
      setState(() {
        // 去重后追加：offset 分页在列表变动时会重复返回同一项。
        for (final g in page) {
          if (_seenIds.add(g.id)) _groups.add(g);
        }
        // 返回数量不足一页即认为到底。
        //
        // 不用「返回空列表」判断：服务端可能因去重后恰好全被过滤而返回空，
        // 但后面还有数据——用「原始返回条数 < pageSize」更准确。
        _hasMore = page.length >= widget.pageSize;
        _loading = false;
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _groups.clear();
      _seenIds.clear();
      _hasMore = true;
      _error = null;
    });
    await _loadMore();
  }

  /// 收集意图并交给调用方，然后按权威结果更新本地列表。
  Future<void> _handleAction(ChatGroup group, GroupAction action) async {
    final handler = widget.onGroupAction;
    if (handler == null || _busyGroupId != null) return;

    setState(() => _busyGroupId = group.id);
    GroupActionResult result;
    try {
      result = await handler(group, action);
    } on SpbError catch (e) {
      // 网络/解析失败：不是业务拒绝，但页面同样只提示、不崩溃。
      result = GroupActionRejected(e.message);
    } finally {
      if (mounted) setState(() => _busyGroupId = null);
    }
    if (!mounted) return;

    switch (result) {
      case GroupActionApplied(group: final updated):
        setState(() {
          final index = _groups.indexWhere((g) => g.id == group.id);
          if (index < 0) return;
          if (updated == null) {
            // 删除成功：从列表移除，并把 id 从去重集合里放开——
            // 否则若同名 id 之后又被服务端返回（理论上不该发生），会因
            // 「已见过」而被静默丢弃，表现为列表少一项。
            _groups.removeAt(index);
            _seenIds.remove(group.id);
          } else {
            // 改名/归档：换成服务端返回的权威对象，而不是本地拼一个。
            // 本地拼会漏掉服务端同时更新的 `updated_at` 等字段，表现为
            // 「列表时间没变，下拉刷新后才跳」。
            _groups[index] = updated;
          }
        });
      case GroupActionRejected(:final message):
        _showMessage(message, isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? scheme.errorContainer : null,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('对话'),
        actions: [
          if (widget.onSearch != null)
            IconButton(
              key: const ValueKey('group-list-search'),
              icon: const Icon(Icons.search),
              tooltip: '搜索消息',
              onPressed: widget.onSearch,
            ),
          if (widget.onOpenWorks != null)
            IconButton(
              key: const ValueKey('group-list-works'),
              icon: const Icon(Icons.work_outline),
              tooltip: '工作台',
              onPressed: widget.onOpenWorks,
            ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _refresh, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    // 首次加载：居中转圈。
    if (_groups.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // 首次加载失败：整页错误 + 重试。
    if (_groups.isEmpty && _error != null) {
      return _FullPageError(error: _error!, onRetry: _loadMore);
    }

    if (_groups.isEmpty) {
      return const _EmptyState();
    }

    return ScrollConfiguration(
      // 桌面端鼠标拖拽（同 conversation_page.dart）。
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: ListView.separated(
        controller: _scrollController,
        // RefreshIndicator 需要列表始终可滚动才能下拉（内容不足一屏时）。
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _groups.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == _groups.length) return _buildFooter();
          final group = _groups[index];
          return _GroupTile(
            key: ValueKey(group.id),
            group: group,
            onTap: widget.onOpenGroup == null
                ? null
                : () => widget.onOpenGroup!(group),
            // 动作进行中时禁用菜单，避免重复提交（见 _busyGroupId）。
            onAction: widget.onGroupAction == null || _busyGroupId != null
                ? null
                : (action) => _handleAction(group, action),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    if (_error != null) {
      // 加载更多失败：底部内联重试，不清空已有列表（用户仍能用已有数据）。
      return Padding(
        padding: SpbSpacing.pagePadding,
        child: Column(
          children: [
            Text(
              _error!.message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: SpbSpacing.sm),
            OutlinedButton(onPressed: _loadMore, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(SpbSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: SpbSpacing.pagePadding,
        child: Center(
          child: Text('没有更多了', style: Theme.of(context).textTheme.labelSmall),
        ),
      );
    }
    return const SizedBox(height: SpbSpacing.xxl);
  }
}

/// 单个对话条目。
///
/// ## 管理入口的触发方式：长按 + 右键
///
/// - **长按**：移动端唯一可行的方式（没有右键）；
/// - **右键**：桌面端自然的方式（`GestureDetector.onSecondaryTapDown`）。
///
/// 两者都打开同一个菜单。**不用**滑动（`Dismissible`）直接删：删除不可恢复，
/// 滑动太容易误触，且无法承载「改名/归档」这类同级动作。
class _GroupTile extends StatelessWidget {
  const _GroupTile({
    super.key,
    required this.group,
    this.onTap,
    this.onAction,
  });

  final ChatGroup group;
  final VoidCallback? onTap;

  /// 为 null 表示不提供管理入口（只读用法）。
  final void Function(GroupAction action)? onAction;

  /// 打开菜单并把用户选择交给 [onAction]。
  Future<void> _openMenu(BuildContext context, Offset position) async {
    final action = await showMenu<GroupAction>(
      context: context,
      // 右键时菜单出现在指针处；长按时出现在条目中心。
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          key: ValueKey('group-action-rename'),
          value: RenameGroup(''),
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text('重命名'),
          ),
        ),
        if (group.isArchived)
          const PopupMenuItem(
            key: ValueKey('group-action-unarchive'),
            value: UnarchiveGroup(),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.unarchive_outlined),
              title: Text('取消归档'),
            ),
          )
        else
          const PopupMenuItem(
            key: ValueKey('group-action-archive'),
            value: ArchiveGroup(),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.archive_outlined),
              title: Text('归档'),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          key: ValueKey('group-action-delete'),
          value: DeleteGroup(),
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline),
            title: Text('删除'),
          ),
        ),
      ],
    );
    if (action == null || !context.mounted) return;

    // 「重命名」的菜单项带的是空标题（菜单在打开前还不知道用户要输入什么），
    // 真正的新标题在这里收集。
    if (action is RenameGroup) {
      final title = await _promptRename(context);
      if (title == null) return;
      onAction?.call(RenameGroup(title));
      return;
    }

    // 删除不可恢复，必须确认。
    if (action is DeleteGroup) {
      final confirmed = await _confirmDelete(context);
      if (confirmed != true) return;
    }

    onAction?.call(action);
  }

  /// 收集新标题；返回 null 表示取消、输入为空、或标题未改动。
  Future<String?> _promptRename(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initialTitle: group.title),
    );
    final trimmed = result?.trim();
    // 空标题服务端会拒绝（且「改成空」几乎不可能是用户意图），本地直接拦掉。
    if (trimmed == null || trimmed.isEmpty) return null;
    // 没改动就别发请求（省一次往返，也避免把列表里的 updated_at 白白推新）。
    if (trimmed == group.title) return null;
    return trimmed;
  }

  /// 删除确认；返回 null 表示用户取消。
  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('group-delete-dialog'),
        title: const Text('删除对话'),
        content: Text('「${group.title}」将被永久删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('group-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final tile = ListTile(
      onTap: onTap,
      title: Text(group.title, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          if (group.isArchived) ...[
            // 归档状态必须可见：否则用户会奇怪为什么这个对话不更新。
            Icon(
              Icons.archive_outlined,
              size: SpbSpacing.md,
              color: scheme.outline,
            ),
            const SizedBox(width: SpbSpacing.xs),
            Text('已归档', style: textTheme.labelSmall),
            const SizedBox(width: SpbSpacing.sm),
          ],
          Text(
            _relativeTime(group.updatedAt),
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
    );

    if (onAction == null) return tile;

    // 用 GestureDetector 包一层而不是 ListTile.onLongPress：
    // 需要同时拿到右键的**指针位置**（菜单要出现在鼠标处），而
    // ListTile 的 onLongPress 不带位置参数。
    return GestureDetector(
      onLongPressStart: (details) =>
          _openMenu(context, details.globalPosition),
      onSecondaryTapDown: (details) =>
          _openMenu(context, details.globalPosition),
      // 让 ListTile 自己处理点击：GestureDetector 的 opaque 会吃掉手势，
      // 故只挂长按/右键，不设 onTap。
      child: tile,
    );
  }

  /// 相对时间（「3 分钟前」）。
  ///
  /// 不用绝对时间戳：对话列表里用户关心的是「多久没动过」，
  /// 而精确到秒的时间需要用户自己做减法。
  static String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

/// 重命名对话框。
///
/// ## 为什么是 StatefulWidget 而不是在 `_promptRename` 里建 controller
///
/// 对话框关闭时有一个**退场动画**（约 150ms），期间 `TextField` 仍在树上、
/// 仍会读 controller。若在 `await showDialog(...)` 返回后立刻 `dispose()`，
/// 动画帧里就会抛「A TextEditingController was used after being disposed」。
///
/// 交给 StatefulWidget 后，Flutter 会在对话框**真正从树上移除后**才调用
/// [State.dispose]——时序天然正确，不必手写延迟。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('group-rename-dialog'),
      title: const Text('重命名对话'),
      content: TextField(
        key: const ValueKey('group-rename-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '标题'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('group-rename-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 整页错误。
class _FullPageError extends StatelessWidget {
  const _FullPageError({required this.error, required this.onRetry});

  final SpbError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: SpbSpacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: SpbSpacing.xxxl,
              color: scheme.error,
            ),
            const SizedBox(height: SpbSpacing.md),
            Text(error.message, textAlign: TextAlign.center),
            const SizedBox(height: SpbSpacing.lg),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 空状态。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 用 ListView 而非 Center：让 RefreshIndicator 在空列表上仍可下拉。
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
        Center(
          child: Column(
            children: [
              Icon(
                Icons.chat_bubble_outline,
                size: SpbSpacing.xxxl,
                color: scheme.outline,
              ),
              const SizedBox(height: SpbSpacing.md),
              Text(
                '还没有对话',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

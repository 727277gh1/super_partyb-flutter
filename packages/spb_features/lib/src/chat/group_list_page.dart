import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

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
    this.pageSize = 30,
  });

  final ChatApi api;

  /// 点击某个对话时的回调。
  final void Function(ChatGroup group)? onOpenGroup;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('对话')),
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
class _GroupTile extends StatelessWidget {
  const _GroupTile({super.key, required this.group, this.onTap});

  final ChatGroup group;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListTile(
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

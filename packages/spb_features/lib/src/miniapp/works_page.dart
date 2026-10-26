import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 加载工作列表。
///
/// `status` 只用两个值：`active`（默认，只列活跃）/ `all`（含归档）。
/// **不要**传别的值——服务端只在 `status == "all"` 时不过滤，其余一律退回
/// 「只列活跃」且**不报错**（`listWorks` 的 `DefaultQuery` + 条件分支）。
///
/// `cursor` 是 **offset**（服务端 `parseOffset`），故类型是 `int?` 而不是
/// `String?`——从签名上挡住「当成不透明游标」的误用。
typedef LoadMiniappWorks = Future<MiniappWorkPage> Function({
  String status,
  int? cursor,
});

/// 打开某个工作（进入详情页）。
typedef OpenMiniappWork = void Function(MiniappWork work);

/// 新建工作（`POST /chat/miniapp/works`）。返回新工作的 id（= group id）。
///
/// ## 为什么没有 `templateId` 参数
///
/// 服务端 `template_id` 是**可选**的（`internal/server/miniapp.go` 的
/// `createWork` 把它直接写进 `metadata`，**没有** `binding:"required"`）。
/// Taro 参考实现也是 `client.createWork({})` 空参调用（见
/// `apps/miniapp/src/pages/work-list/work-list.tsx` 的 `createNewWork`）。
/// 故不需要模板选择器——若将来服务端要求模板，这里会以 400 暴露出来。
///
/// `goal` 同样可选：服务端留空（NULL）而非写占位符（写占位符会让会话设置
/// 面板把占位符当已配置目标回显）。
///
/// 返回值供调用方导航到新工作；本页不导航（见 [_WorksPageState._create]）。
typedef CreateMiniappWork = Future<String> Function();

/// 工作列表页（小程序工作台）。
///
/// ## 分页是 offset，但**返回值的名字叫 `next_cursor`**
///
/// `listWorks` 返回 `next_cursor = strconv.Itoa(offset + len(groups))`。
/// 名字是游标、值其实是 offset。与 `GroupListPage` 同样必须**按 id 去重**：
/// offset 分页在列表变动时窗口会移动，产生重复项 → Flutter 重复 Key 崩溃。
///
/// ## 与对话列表的关系
///
/// 工作的 `id` **就是 group id**（服务端没有 works 表）。所以点进详情后若想
/// 跳回对话流，用同一个 id 即可。
///
/// ## 页面不调 API
///
/// 全部依赖注入（同 [GroupListPage] / [SearchPage]），故可在 widget test 里
/// 完整验证分页、去重、状态过滤与错误分支，无需 HTTP mock。
class WorksPage extends StatefulWidget {
  const WorksPage({
    super.key,
    required this.loadWorks,
    this.onOpenWork,
    this.onCreateWork,
    this.pageSize = 20,
    this.title = '工作台',
  });

  final LoadMiniappWorks loadWorks;

  /// 为 null 时条目不可点击（保持「只读预览」用法）。
  final OpenMiniappWork? onOpenWork;

  /// 新建工作。为 null 时不展示「新建」按钮（只读用法）。
  ///
  /// 创建成功后由本页负责刷新列表，并（若 [onOpenWork] 非空）导航到新工作。
  final CreateMiniappWork? onCreateWork;

  final int pageSize;
  final String title;

  @override
  State<WorksPage> createState() => _WorksPageState();
}

class _WorksPageState extends State<WorksPage> {
  final _scrollController = ScrollController();
  final _works = <MiniappWork>[];

  /// 已见过的 id（offset 分页去重，见类文档）。
  final _seenIds = <String>{};

  /// 服务端返回的 `next_cursor`（实为 offset 字符串）。
  int? _cursor;
  bool _hasMore = true;
  bool _loading = false;
  SpbError? _error;

  /// 当前状态过滤（`active` / `all`）。
  String _status = 'active';

  /// 正在新建工作（防重复提交）。
  ///
  /// 与 [_loading] 分开：新建不应该让整个列表变成加载态（用户还在看旧内容），
  /// 只禁用触发它的那个按钮。
  bool _creating = false;

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
    // 提前一屏预加载，避免用户滚到底时看到白屏。
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
      final page = await widget.loadWorks(status: _status, cursor: _cursor);
      if (!mounted) return;

      var added = 0;
      for (final w in page.items) {
        // offset 分页去重：窗口移动会产生重复项，重复 Key 会让 Flutter 崩溃。
        if (_seenIds.add(w.id)) {
          _works.add(w);
          added++;
        }
      }

      // ## 为什么用「本次新增数」而不是「本页条数」判有无更多
      //
      // 服务端 `next_cursor` 只在 `len(groups) == limit` 时非空。若整页都是
      // 重复项（added == 0）却仍有 cursor，继续翻会陷入死循环。用 added 判定
      // 可以立即止损。
      setState(() {
        _cursor = int.tryParse(page.nextCursor ?? '');
        _hasMore = page.hasMore && added > 0;
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

  Future<void> _reload() async {
    setState(() {
      _works.clear();
      _seenIds.clear();
      _cursor = null;
      _hasMore = true;
    });
    await _loadMore();
  }

  Future<void> _switchStatus(String status) async {
    if (_status == status) return;
    setState(() => _status = status);
    await _reload();
  }

  /// 新建工作。
  ///
  /// ## 为什么不新起轮询等「工作就绪」
  ///
  /// 服务端 `createWork` 是同步的（建组 + 可选派发首条消息后返回完整
  /// work detail），没有「创建中」这个中间态。故直接刷新列表即可。
  ///
  /// ## 为什么不在这里导航到新工作
  ///
  /// 导航目标（push / go / 是否带其他参数）是装配层的事，与 [onOpenWork]
  /// 同一约定。且新工作的标题是占位符「新会话」（服务端刻意如此：Title Gate
  /// 靠识别占位符才会在首轮后生成语义标题），本页拿到的只是一个 id，造不出
  /// 完整的 `MiniappWork`。故由调用方在闭包里自行导航。
  Future<void> _create() async {
    final create = widget.onCreateWork;
    if (create == null || _creating) return;

    setState(() => _creating = true);
    try {
      await create();
      if (!mounted) return;
      // 刷新放在调用方导航之后（若调用方导航了，本页已不在树上，mounted 为
      // false 时直接返回）。不刷新的话，用户返回列表时看到的仍是旧数据。
      await _reload();
    } on SpbError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('新建工作失败：${e.message}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('miniapp-works-page'),
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // 新建：只在注入了实现时展示（只读用法不显示）。
          if (widget.onCreateWork != null)
            IconButton(
              key: const ValueKey('miniapp-works-create'),
              tooltip: '新建工作',
              icon: _creating
                  ? const SizedBox(
                      width: SpbSpacing.lg,
                      height: SpbSpacing.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              onPressed: _creating ? null : _create,
            ),
          // 状态过滤：`all` 才会列出已归档（完成/停止的工作会归档）。
          PopupMenuButton<String>(
            key: const ValueKey('miniapp-works-status-filter'),
            tooltip: '显示范围',
            initialValue: _status,
            onSelected: _switchStatus,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'active', child: Text('进行中')),
              PopupMenuItem(value: 'all', child: Text('全部（含已归档）')),
            ],
          ),
          IconButton(
            key: const ValueKey('miniapp-works-refresh'),
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // 加载失败且无内容：整屏错误 + 重试。
    if (_error != null && _works.isEmpty) {
      return Center(
        key: const ValueKey('miniapp-works-error'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: SpbSpacing.xxl,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text('加载工作列表失败：${_error!.message}', textAlign: TextAlign.center),
              const SizedBox(height: SpbSpacing.md),
              FilledButton(
                key: const ValueKey('miniapp-works-retry'),
                onPressed: _reload,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 首屏加载中。
    if (_works.isEmpty && _loading) {
      return const Center(
        key: ValueKey('miniapp-works-loading'),
        child: CircularProgressIndicator(),
      );
    }

    if (_works.isEmpty) {
      return Center(
        key: const ValueKey('miniapp-works-empty'),
        child: Text(
          _status == 'active' ? '还没有进行中的工作' : '还没有任何工作',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        controller: _scrollController,
        padding: SpbSpacing.pagePadding,
        // +1 给底部加载指示器。
        itemCount: _works.length + 1,
        itemBuilder: (context, index) {
          if (index == _works.length) return _buildFooter();
          final work = _works[index];
          return _WorkCard(
            key: ValueKey('miniapp-work-${work.id}'),
            work: work,
            onTap: widget.onOpenWork == null
                ? null
                : () => widget.onOpenWork!(work),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    // 分页请求失败：**只**在底部提示 + 重试，不清空已有列表
    // （用户已经看到的内容不该因为下一页失败而消失）。
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: SpbSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                '加载更多失败：${_error!.message}',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              key: const ValueKey('miniapp-works-more-retry'),
              onPressed: _loadMore,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: SpbSpacing.md),
        child: Center(
          child: SizedBox(
            width: SpbSpacing.lg,
            height: SpbSpacing.lg,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return const SizedBox(height: SpbSpacing.lg);
  }
}

/// 工作卡片。
class _WorkCard extends StatelessWidget {
  const _WorkCard({super.key, required this.work, this.onTap});

  final MiniappWork work;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(bottom: SpbSpacing.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: SpbRadius.cardAll,
        child: Padding(
          padding: SpbSpacing.cardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      work.title.isEmpty ? '（未命名工作）' : work.title,
                      style: textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: SpbSpacing.sm),
                  _StatusChip(work: work),
                ],
              ),
              if (work.goal != null && work.goal!.isNotEmpty) ...[
                const SizedBox(height: SpbSpacing.xs),
                Text(
                  work.goal!,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (work.progress.hasSteps) ...[
                const SizedBox(height: SpbSpacing.sm),
                // 用 fraction 而不是 percent/100：服务端 percent 是整数，
                // 1/3 会被舍成 33%。有 total 时 completed/total 更精确。
                LinearProgressIndicator(value: work.progress.fraction),
                const SizedBox(height: SpbSpacing.xxs),
                Text(
                  '${work.progress.completed}/${work.progress.total}'
                  '${work.progress.currentStepTitle == null ? '' : ' · ${work.progress.currentStepTitle}'}',
                  style: textTheme.labelSmall,
                ),
              ],
              if (work.latestSummary != null &&
                  work.latestSummary!.isNotEmpty) ...[
                const SizedBox(height: SpbSpacing.sm),
                Text(
                  work.latestSummary!,
                  style: textTheme.bodySmall,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (work.hasPendingConfirmation) ...[
                const SizedBox(height: SpbSpacing.sm),
                Row(
                  children: [
                    Icon(
                      Icons.help_outline,
                      size: SpbSpacing.md,
                      color: scheme.tertiary,
                    ),
                    const SizedBox(width: SpbSpacing.xs),
                    Text(
                      '${work.pendingConfirmationCount} 项待确认',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.tertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态徽标。
///
/// 文案优先用服务端下发的 [MiniappWork.displayStatus]：状态表在服务端，
/// 前端硬编码会漂移（历史上两份前端表已经漂移过）。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.work});

  final MiniappWork work;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (work.status) {
      'running' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'waiting_user' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      'completed' => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      'failed' => (scheme.errorContainer, scheme.onErrorContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(SpbRadius.pill),
      ),
      child: Text(
        work.displayStatus,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

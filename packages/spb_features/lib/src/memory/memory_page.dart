import 'dart:async';

import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_ui/spb_ui.dart';

/// 每页条数（默认值；测试可注入更小的 [MemoryPage.pageSize]）。
///
/// 服务端 `parseLimit(c.Query("limit"), 200, 1000)`：默认 200、上限 1000。这里取
/// 100 —— 首屏更快，且「还有下一页」的判据是 `items.length == pageSize`
/// （前提见 [LoadMemories]）。
const int kMemoryPageSize = 100;

/// 距底不足这么多像素时预取下一页（触屏 / 滚轮路径）。
const double _loadMoreThreshold = 240;

/// 拉取一页记忆。参数是状态筛选（`null` = 全部，对应 `?status=`）+ 分页窗口。
///
/// ## 为什么可以用「满页」判断还有下一页
///
/// 服务端曾把 `status` / `category` 过滤放在**应用层**（先 `LIMIT/OFFSET` 取、
/// 再筛），于是每页条数不稳定，`offset += limit` 翻页必然漏项（本页的前置
/// super_partyb#191）。现已修（`23b61b69`）：过滤下推 SQL、`ORDER BY created_at
/// DESC, id DESC` 补了稳定 tiebreak，过滤与分页在**同一窗口**内生效 —— 故
/// `items.length == limit` 就是「可能还有下一页」，`offset += limit` 不再漏项。
typedef LoadMemories = Future<List<UserMemory>> Function(
  UserMemoryStatus? status, {
  int limit,
  int offset,
});

/// 编辑一条记忆（`PATCH /api/memories/:id` 的增量语义）。
typedef UpdateMemory = Future<UserMemory> Function(
  String memoryId, {
  String? content,
  UserMemoryCategory? category,
  UserMemoryStatus? status,
});

/// 归档（软删）。恢复走 [UpdateMemory] 的 `status: active`。
typedef ArchiveMemory = Future<void> Function(String memoryId);

/// 用户记忆页。
///
/// ## 产品形态对齐 webapp（`dashboard/memories/page.tsx`）
///
/// | webapp | 本页 |
/// |---|---|
/// | `statusFilter`（active / archived / all，默认 active） | 顶部筛选 chip |
/// | 按 `category` 分桶、桶内按 `updatedAt` 倒序 | 同 |
/// | `MemoryCard`：正文 + 来源 + 相对时间 | 同 |
/// | `EditMemoryDialog`：内容 / 分类 / 状态 | [MemoryEditDialog] |
/// | 归档是软删，「归档后提取器不再据此学习」 | 归档按钮 + 恢复按钮 |
///
/// ## 分页（issue #121）
///
/// 首屏只取一页，底部哨兵（滚到距底 [_loadMoreThreshold] px 内）与「加载更多」
/// 按钮**两个触发点**都能继续翻页：前者给触屏 / 滚轮，后者给键盘、读屏与测试
/// （阈值在无头环境里不可确定性触发，只藏一个隐式触发器等于不可测）。
///
/// 两条容易漏的细节：
///
/// 1. **条目离开当前筛选时要回退 offset**：在「生效中」筛选下归档一条，服务端的
///    active 窗口会整体上移一格；若仍按 `offset += limit` 继续翻页，上移过来的
///    那条永远取不到。故 [_replace] 按「移除条数」同步回退下一页起点，追加时再按
///    id 去重——回退带来的重叠窗口不会出现两条同一记忆；
/// 2. **切筛选必须把 offset 归零**：`_load` 是全量重取（`offset: 0`），`_requestId`
///    会让在途的翻页响应作废，否则旧筛选的第二页会被追加到新列表里。
///
/// ## 为什么不做「新建记忆」
///
/// 服务端内部面 `POST /api/memories` 要求 `topic_id`（服务端解析 topic_key 后
/// 写入的内部外键），客户端没有合法值来源；外部面 `/open/memories` 要 API Key
/// （客户端不持有，AGENTS §5.1）。而记忆本来由提取器写入——用户来这一页的诉求
/// 是「看它在记什么、改掉/删掉记错的」，不是手工记账。
///
/// ## 为什么是独立页面而不是设置页的一个标签
///
/// webapp / 小程序都把它与习惯并列成一级页面（`sidebar.tsx:309-315`）；
/// 它是「对话的衍生视图」（记忆是从对话里学到的），从列表页进比从设置进更符合
/// 心智（与 `/habits`、`/my-turns` 同一挂载层级）。
class MemoryPage extends StatefulWidget {
  const MemoryPage({
    super.key,
    required this.loadMemories,
    this.updateMemory,
    this.archiveMemory,
    this.onOpenGroup,
    this.groupTitleOf,
    this.pageSize = kMemoryPageSize,
  });

  /// 拉取记忆（`GET /api/memories`）。
  final LoadMemories loadMemories;

  /// 编辑（内容 / 分类 / 状态）。为 null 时不渲染「编辑」与「恢复」入口。
  final UpdateMemory? updateMemory;

  /// 归档。为 null 时不渲染「归档」入口。
  final ArchiveMemory? archiveMemory;

  /// 跳到来源对话。为 null 时来源只作文字展示。
  final void Function(String groupId)? onOpenGroup;

  /// groupId → 标题。为 null 或返回 null 时退化为显示 id。
  final String? Function(String groupId)? groupTitleOf;

  /// 每页条数。生产恒为 [kMemoryPageSize]；测试注入小值，避免为了触发「满页」
  /// 而在 widget test 里渲染上百张卡片。
  final int pageSize;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  /// 当前筛选；`null` = 全部。
  UserMemoryStatus? _status = UserMemoryStatus.active;

  List<UserMemory>? _memories;
  bool _loading = false;

  /// 最近一次加载失败的原因。
  ///
  /// 类型是 `Object` 而不是 `SpbError`：装配层应已归一（`SpbApi` 抛 `SpbError`），
  /// 但本页不依赖这个前提——未归一的异常也必须能显示成一句话而不是崩溃
  /// （`HabitsPage` 的 `_error` 同一取向）。
  Object? _error;

  /// 正在提交的条目 id（并发保护：归档/恢复按钮在往返期间禁用）。
  final Set<String> _busy = <String>{};

  /// 请求代际：切筛选时旧请求的结果必须丢弃，否则会闪回上一次的列表。
  int _requestId = 0;

  /// 下一页的 `offset`（服务端窗口已消费的条数，**不是**本地列表长度）。
  ///
  /// 两者在「有条目离开当前筛选」时分叉，见类文档「分页」第 1 条。
  int _nextOffset = 0;

  /// 上一页是否满页（`items.length == pageSize`）→ 可能还有下一页。
  bool _hasMore = false;

  /// 正在加载下一页（滚动阈值去抖与 footer 进度条共用）。
  bool _loadingMore = false;

  /// 加载下一页失败的原因；只影响 footer，不清空已加载的列表。
  Object? _moreError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 全量重取第一页（首屏、刷新、切筛选都走这里）。
  Future<void> _load() async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      // 在途的翻页响应随 `_requestId` 作废，但它的「正在加载」标志得在这里清掉，
      // 否则 footer 会一直转圈。
      _loadingMore = false;
      _moreError = null;
    });
    try {
      final items = await widget.loadMemories(
        _status,
        limit: widget.pageSize,
        offset: 0,
      );
      if (!mounted || id != _requestId) return;
      setState(() {
        _memories = items;
        _nextOffset = items.length;
        _hasMore = items.length == widget.pageSize;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted || id != _requestId) return;
      if (e is! SpbError) {
        // 纵深防御：装配层应已把 Dio / 解析异常翻成 SpbError（与 HabitsPage 同）。
        SpbLog.debug('记忆列表加载失败（未归一的异常）', {'error': e.toString()});
      }
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 取下一页并追加。幂等：滚动阈值会连续发通知，`_loadingMore` / `_hasMore`
  /// 双重闸保证只打一次请求。
  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final id = _requestId;
    final offset = _nextOffset;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final page = await widget.loadMemories(
        _status,
        limit: widget.pageSize,
        offset: offset,
      );
      if (!mounted || id != _requestId) return;
      setState(() {
        final current = _memories ?? const <UserMemory>[];
        // 回退 offset 会让同一窗口被取两次，按 id 去重（类文档「分页」第 1 条）。
        final ids = <String>{for (final m in current) m.id};
        final fresh = <UserMemory>[
          for (final m in page)
            if (ids.add(m.id)) m,
        ];
        _memories = <UserMemory>[...current, ...fresh];
        _nextOffset = offset + page.length;
        _hasMore = page.length == widget.pageSize;
        _loadingMore = false;
      });
    } on Object catch (e) {
      if (!mounted || id != _requestId) return;
      if (e is! SpbError) {
        // 纵深防御：装配层应已归一（与 `_load` 同）。
        SpbLog.debug('记忆下一页加载失败（未归一的异常）', {'error': e.toString()});
      }
      setState(() {
        _moreError = e;
        _loadingMore = false;
      });
    }
  }

  void _setStatus(UserMemoryStatus? status) {
    if (_status == status) return;
    setState(() {
      _status = status;
      // 旧列表先清掉：切到「已归档」还留着一屏 active 条目，用户会以为筛选没生效。
      _memories = null;
      // 分页窗口也随之归零：新筛选的第一页就是 `offset: 0`（`_load` 会重取）。
      _nextOffset = 0;
      _hasMore = false;
      _loadingMore = false;
      _moreError = null;
    });
    _load();
  }

  Future<void> _toggleArchive(UserMemory memory) async {
    if (_busy.contains(memory.id)) return;
    final archive = widget.archiveMemory;
    final update = widget.updateMemory;
    final isArchiving = memory.isActive;
    if (isArchiving ? archive == null : update == null) return;

    setState(() => _busy.add(memory.id));
    try {
      if (isArchiving) {
        await archive!(memory.id);
      } else {
        await update!(memory.id, status: UserMemoryStatus.active);
      }
      if (!mounted) return;
      _replace(
        memory.copyWith(
          status: isArchiving
              ? UserMemoryStatus.archived
              : UserMemoryStatus.active,
        ),
      );
      _toast(isArchiving ? '已归档，提取器不再据此学习' : '已恢复');
    } on Object catch (e) {
      if (!mounted) return;
      _toast(_describe(e));
    } finally {
      if (mounted) setState(() => _busy.remove(memory.id));
    }
  }

  Future<void> _edit(UserMemory memory) async {
    final update = widget.updateMemory;
    if (update == null) return;
    final result = await showDialog<MemoryDraft>(
      context: context,
      builder: (context) => MemoryEditDialog(memory: memory),
    );
    if (result == null || !mounted) return;

    setState(() => _busy.add(memory.id));
    try {
      final updated = await update(
        memory.id,
        content: result.content,
        category: result.category,
        status: result.status,
      );
      if (!mounted) return;
      _replace(updated);
      _toast('已保存');
    } on Object catch (e) {
      if (!mounted) return;
      _toast(_describe(e));
    } finally {
      if (mounted) setState(() => _busy.remove(memory.id));
    }
  }

  /// 用更新后的条目替换列表项；若其状态不再符合当前筛选则移除。
  void _replace(UserMemory updated) {
    final current = _memories;
    if (current == null) return;
    final next = current
        .map((m) => m.id == updated.id ? updated : m)
        .where(_matches)
        .toList(growable: false);
    final removed = current.length - next.length;
    setState(() {
      // 条目离开当前筛选 → 服务端窗口整体上移一格：下一页起点同步回退，否则下一次
      // 翻页会漏掉上移过来的那条（类文档「分页」第 1 条）。追加侧按 id 去重，
      // 所以回退造成的重叠窗口不会出现重复条目。
      if (removed > 0) {
        final back = _nextOffset - removed;
        _nextOffset = back < 0 ? 0 : back;
      }
      _memories = next;
    });
  }

  bool _matches(UserMemory m) {
    final status = _status;
    return status == null || m.status == status;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 把异常翻成一句用户可读的话。
  ///
  /// `SpbError.message` 由装配层/`spb_api` 负责本地化（服务端 `{error: ..}`
  /// 的内容直接透出）；其余异常不把 `toString()` 铺到界面上。
  static String _describe(Object e) =>
      e is SpbError && e.message.isNotEmpty ? e.message : '操作失败，请稍后重试';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆'),
        actions: [
          IconButton(
            key: const ValueKey('memory-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildFilterBar(context),
          const Divider(height: 1),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.lg,
        vertical: SpbSpacing.sm,
      ),
      child: Row(
        children: [
          _filterChip('memory-filter-active', '生效中', UserMemoryStatus.active),
          const SizedBox(width: SpbSpacing.sm),
          _filterChip(
            'memory-filter-archived',
            '已归档',
            UserMemoryStatus.archived,
          ),
          const SizedBox(width: SpbSpacing.sm),
          _filterChip('memory-filter-all', '全部', null),
        ],
      ),
    );
  }

  Widget _filterChip(String key, String label, UserMemoryStatus? value) {
    return ChoiceChip(
      key: ValueKey(key),
      label: Text(label),
      selected: _status == value,
      onSelected: (_) => _setStatus(value),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _memories == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = _error;
    if (err != null && _memories == null) {
      return ErrorState(
        message: _describe(err),
        onRetry: _load,
        retryKey: const ValueKey('memory-retry'),
      );
    }
    final items = _memories ?? const <UserMemory>[];
    if (items.isEmpty) {
      return EmptyState(
        message: switch (_status) {
          UserMemoryStatus.active => '还没有生效中的记忆。\n对话里学到的偏好与事实会自动出现在这里。',
          UserMemoryStatus.archived => '没有已归档的记忆。',
          _ => '还没有记忆。',
        },
        icon: Icons.psychology_outlined,
      );
    }

    // 按分类分桶（对齐 webapp 的 `grouped`）：桶内按 updatedAt 倒序。
    final buckets = <UserMemoryCategory, List<UserMemory>>{};
    for (final m in items) {
      buckets.putIfAbsent(m.category, () => <UserMemory>[]).add(m);
    }
    for (final list in buckets.values) {
      list.sort(
        (a, b) =>
            (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
      );
    }
    final ordered = <UserMemoryCategory>[
      for (final c in UserMemoryCategory.values)
        if (c != UserMemoryCategory.unknown) c,
      UserMemoryCategory.unknown,
    ];

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 距底不足阈值就预取下一页。`_loadMore` 自己是幂等的，滚动期间连续
        // 通知只会打一次请求。
        if (notification.metrics.extentAfter < _loadMoreThreshold) {
          unawaited(_loadMore());
        }
        return false;
      },
      child: ListView(
        key: const ValueKey('memory-list'),
        padding: const EdgeInsets.fromLTRB(
          SpbSpacing.lg,
          SpbSpacing.md,
          SpbSpacing.lg,
          SpbSpacing.xxl,
        ),
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(bottom: SpbSpacing.md),
              child: LinearProgressIndicator(),
            ),
          for (final category in ordered) ...[
            if (buckets[category] != null) ...[
              Padding(
                padding: const EdgeInsets.only(
                  top: SpbSpacing.sm,
                  bottom: SpbSpacing.xs,
                ),
                child: Text(
                  category.label,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              for (final memory in buckets[category]!) _buildCard(memory),
            ],
          ],
          _buildFooter(context),
        ],
      ),
    );
  }

  /// 列表尾部：加载中 / 失败重试 / 「加载更多」/ 到底（不渲染）。
  ///
  /// 与滚动阈值**并存**：阈值那条给触屏与滚轮（无按钮也能翻），这条给键盘、
  /// 读屏和 widget test（阈值在无头环境里不可确定性触发）。
  Widget _buildFooter(BuildContext context) {
    if (_loadingMore) {
      return const Padding(
        key: ValueKey('memory-more-progress'),
        padding: EdgeInsets.symmetric(vertical: SpbSpacing.lg),
        child: LinearProgressIndicator(),
      );
    }
    final err = _moreError;
    if (err != null) {
      return Padding(
        key: const ValueKey('memory-more-error'),
        padding: const EdgeInsets.symmetric(vertical: SpbSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '加载更多失败：${_describe(err)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              key: const ValueKey('memory-more-retry'),
              onPressed: () => unawaited(_loadMore()),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!_hasMore) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SpbSpacing.sm),
      child: Center(
        child: TextButton(
          key: const ValueKey('memory-load-more'),
          onPressed: () => unawaited(_loadMore()),
          child: const Text('加载更多'),
        ),
      ),
    );
  }

  Widget _buildCard(UserMemory memory) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final busy = _busy.contains(memory.id);
    final groupId = memory.sourceGroupId;
    final groupTitle = groupId == null
        ? null
        : (widget.groupTitleOf?.call(groupId) ?? groupId);

    final meta = <String>[
      if (groupTitle != null && groupTitle.isNotEmpty) '来自「$groupTitle」',
      if (memory.learnedFromTurns > 1) '学过 ${memory.learnedFromTurns} 轮',
      if (memory.lastReinforcedAt != null)
        '${_relativeTime(memory.lastReinforcedAt!)}强化',
    ];

    return Card(
      key: ValueKey('memory-${memory.id}'),
      margin: const EdgeInsets.only(bottom: SpbSpacing.md),
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(memory.content, style: textTheme.bodyMedium),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: SpbSpacing.sm),
              InkWell(
                key: groupId == null
                    ? null
                    : ValueKey('memory-source-${memory.id}'),
                onTap: groupId == null || widget.onOpenGroup == null
                    ? null
                    : () => widget.onOpenGroup!(groupId),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: SpbSpacing.xs),
                  child: Text(
                    meta.join(' · '),
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: SpbSpacing.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.updateMemory != null)
                  TextButton(
                    key: ValueKey('memory-edit-${memory.id}'),
                    onPressed: busy ? null : () => _edit(memory),
                    child: const Text('编辑'),
                  ),
                if (memory.isActive && widget.archiveMemory != null)
                  TextButton(
                    key: ValueKey('memory-archive-${memory.id}'),
                    onPressed: busy ? null : () => _toggleArchive(memory),
                    child: const Text('归档'),
                  ),
                if (!memory.isActive && widget.updateMemory != null)
                  TextButton(
                    key: ValueKey('memory-restore-${memory.id}'),
                    onPressed: busy ? null : () => _toggleArchive(memory),
                    child: const Text('恢复'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 相对时间（「3 分钟前」）。
  ///
  /// ⚠️ 这是本仓库第 4 份同款实现（`search_page` / `my_turns_page` /
  /// `group_list_page` 各一份）。收口到 `spb_ui` 是独立重构（会动 3 个页面的
  /// 断言），不在本轮扩大范围。
  static String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    if (diff.inDays < 365) return '${diff.inDays ~/ 30} 个月前';
    return '${diff.inDays ~/ 365} 年前';
  }
}

/// 编辑记忆对话框的返回值。
class MemoryDraft {
  const MemoryDraft({
    required this.content,
    required this.category,
    required this.status,
  });

  final String content;
  final UserMemoryCategory category;
  final UserMemoryStatus status;
}

/// 编辑记忆：正文 / 分类 / 状态。
///
/// ## 状态是这里改还是列表按钮改
///
/// 两个入口都存在（对齐 webapp 的 `EditMemoryDialog` 同时提供 status 下拉）：
/// 列表按钮是「一键归档/恢复」，对话框是「顺手改分类时也把状态改了」。
/// 两处都走同一个 `PATCH`，没有第二条写路径。
class MemoryEditDialog extends StatefulWidget {
  const MemoryEditDialog({super.key, required this.memory});

  final UserMemory memory;

  @override
  State<MemoryEditDialog> createState() => _MemoryEditDialogState();
}

class _MemoryEditDialogState extends State<MemoryEditDialog> {
  late final TextEditingController _content = TextEditingController(
    text: widget.memory.content,
  );
  late UserMemoryCategory _category = widget.memory.category;
  late UserMemoryStatus _status = widget.memory.status;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('memory-edit-dialog'),
      title: const Text('编辑记忆'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('memory-edit-content'),
                controller: _content,
                maxLines: 5,
                minLines: 3,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  labelText: '内容',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: SpbSpacing.md),
              DropdownButtonFormField<UserMemoryCategory>(
                key: const ValueKey('memory-edit-category'),
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: '分类',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in UserMemoryCategory.values)
                    if (c != UserMemoryCategory.unknown)
                      DropdownMenuItem(value: c, child: Text(c.label)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _category = v);
                },
              ),
              const SizedBox(height: SpbSpacing.md),
              DropdownButtonFormField<UserMemoryStatus>(
                key: const ValueKey('memory-edit-status'),
                initialValue: _status == UserMemoryStatus.dismissed
                    ? UserMemoryStatus.archived
                    : _status,
                decoration: const InputDecoration(
                  labelText: '状态',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final s in const [
                    UserMemoryStatus.active,
                    UserMemoryStatus.archived,
                  ])
                    DropdownMenuItem(value: s, child: Text(s.label)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _status = v);
                },
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text(
                '归档后提取器不再据此学习，可在列表里恢复。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('memory-edit-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('memory-edit-save'),
          onPressed: () {
            final content = _content.text.trim();
            // 服务端把空串当「未传」，空内容提交会静默失败——故客户端直接拦住。
            if (content.isEmpty) return;
            Navigator.of(context).pop(
              MemoryDraft(
                content: content,
                category: _category,
                status: _status,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

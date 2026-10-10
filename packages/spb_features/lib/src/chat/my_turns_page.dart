import 'dart:async';

import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 拉取最近轮次（`GET /me/turns`）。
///
/// 四个参数全部对应服务端 query（`user_turns.go` 的 `list`）：
/// - [days]：时间窗（服务端默认 7、限制 1–90）；
/// - [status]：**精确**匹配 DB `status` 列（不是包含匹配）；
/// - [source]：派生来源（服务端 `deriveTurnSource` 的 5 类）；
/// - [groupId]：只看某个对话。
///
/// 装配层实现即 `ChatApi.listMyTurns`（它多一个带默认值的 `limit`，
/// 属于额外可选具名参数，仍是本 typedef 的子类型）。
typedef FetchMyTurns = Future<List<ChatTurnSummary>> Function({
  int? days,
  String? status,
  String? source,
  String? groupId,
});

/// 按关键词搜索轮次（`GET /me/turns/search`）。
///
/// 装配层实现即 `ChatApi.searchMyTurns`（它多一个带默认值的 `limit`，属于额外
/// 可选具名参数，仍是本 typedef 的子类型）。
///
/// ## 为什么与 [FetchMyTurns] 分开而不是合成一个带 `query` 的回调
///
/// 两个端点的**参数集不相交**：`/me/turns` 认 days/status/source/group_id，
/// `/me/turns/search` 只认 q/limit。合成一个回调会让「搜索时筛选条件也传下去」
/// 变成一件容易顺手写出来的事——而服务端会**静默忽略**它们，表现为「筛了却
/// 没筛」，不报错。分开就写不出这个 bug。
typedef SearchMyTurns = Future<List<ChatTurnSummary>> Function(String query);

/// 搜索输入防抖时长。
///
/// 与服务端 `SearchPage.debounce` 同一经验值：搜索是 `input_text LIKE '%q%'`
/// （无法走索引），逐字符发请求意味着输入「报错排查」会打 4 次全表扫描，而前
/// 3 次的结果用户根本看不到就被后一次覆盖了。
const Duration kMyTurnsSearchDebounce = Duration(milliseconds: 300);

/// 默认时间窗（与服务端默认值一致）。
///
/// 保持 7 而不是扩大：服务端 `if days > 90 { days = 90 }`，而「最近轮次」的
/// 默认用途是「我刚才让它干了什么」，7 天已足够，也避免首拉过多数据。
const int kMyTurnsDefaultDays = 7;

/// 时间窗可选项。
///
/// 上限 90 是服务端硬限制：给出 >90 的选项只会得到被**静默截断**的结果，
/// 展示窗口与真实窗口不符。
const List<int> kMyTurnsDayOptions = [7, 30, 90];

/// 状态筛选项。
///
/// 取值来自 `chat_turns` 的 CHECK 约束
/// （`schema.sql`：`queued|running|completed|failed|cancelled|pending`），
/// 服务端按 `status = ?` **精确**匹配。
///
/// ## 为什么逐值列出而不是像 webapp 那样合成「运行中」
///
/// webapp 的 `running` 选项其实只匹配 `status='running'`，**不含 `queued`**
/// （服务端是等值比较，不是分组）。沿用它会造出「筛了『运行中』却看不到排队中
/// 的轮次」的假象。逐值列出，每个选项都是它字面的意思。
///
/// ⚠️ 取消态是**英式** `cancelled`（`domain.go` 的 `TurnStatusCanceled`）。
const List<({String wire, String label})> kMyTurnsStatusOptions = [
  (wire: 'queued', label: '排队中'),
  (wire: 'running', label: '运行中'),
  (wire: 'pending', label: '待确认'),
  (wire: 'completed', label: '已完成'),
  (wire: 'failed', label: '失败'),
  (wire: 'cancelled', label: '已取消'),
];

/// 来源筛选项（`TurnSource.unknown` 不是可筛选项，故不在此列表）。
const List<TurnSource> kMyTurnsSourceOptions = [
  TurnSource.chat,
  TurnSource.mq,
  TurnSource.schedule,
  TurnSource.habit,
  TurnSource.toolAgent,
];

/// 「我的轮次」的筛选条件。
///
/// 字段与服务端 query 一一对应，null 表示不筛（不发该参数）。
class MyTurnsFilter {
  const MyTurnsFilter({
    this.days = kMyTurnsDefaultDays,
    this.source,
    this.status,
    this.groupId,
  });

  final int days;
  final TurnSource? source;

  /// 服务端 `status` 的精确值（见 [kMyTurnsStatusOptions]）。
  final String? status;

  /// 只看某个对话。
  final String? groupId;

  bool get isDefault =>
      days == kMyTurnsDefaultDays &&
      source == null &&
      status == null &&
      groupId == null;

  MyTurnsFilter copyWith({
    int? days,
    TurnSource? source,
    String? status,
    String? groupId,
    bool clearSource = false,
    bool clearStatus = false,
    bool clearGroup = false,
  }) => MyTurnsFilter(
    days: days ?? this.days,
    source: clearSource ? null : (source ?? this.source),
    status: clearStatus ? null : (status ?? this.status),
    groupId: clearGroup ? null : (groupId ?? this.groupId),
  );

  @override
  bool operator ==(Object other) =>
      other is MyTurnsFilter &&
      other.days == days &&
      other.source == source &&
      other.status == status &&
      other.groupId == groupId;

  @override
  int get hashCode => Object.hash(days, source, status, groupId);

  @override
  String toString() =>
      'MyTurnsFilter(days: $days, source: ${source?.wire}, '
      'status: $status, groupId: $groupId)';
}

/// 「我的最近轮次」列表（对齐 webapp `dashboard/turns`）。
///
/// ## 解决了什么
///
/// 对话列表只按 group 组织，用户看不到「我最近都让 agent 干了什么」。
/// 本页按时间倒序列出跨 group 的最近轮次，点击跳回对应对话。
///
/// ## 为什么不做语义搜索
///
/// 服务端 `/me/turns/semantic-search` **存在但已降级为关键字搜索**
/// （`user_turns.go:217`：embedding 服务未接入 Go API，回退到关键字搜索
/// 并带 `similarity=0` 标记）。做语义搜索 UI 只会给用户「看起来能语义搜、
/// 实际是关键字」的假象，故不做。
///
/// ## 数据来源
///
/// `GET /me/turns`（`user_turns.go` 的 `turnToListItem` 投影）。由调用方注入
/// [fetch]（便于无头单测与 app 层选 provider）。
///
/// ## 关键词搜索（issue #18）
///
/// 注入 [search] 后筛选栏顶部出现搜索框，命中走 `GET /me/turns/search`。
/// [search] 为 null 时**整个搜索框不渲染**（不是禁用）——与
/// `GoalHistoryPanel.onSwitch` 同一约定：不渲染一个点了没反应的入口。
///
/// ### 搜索模式与筛选条件互斥
///
/// `/me/turns/search` 只认 `q` + `limit`，**不认** days/status/source/group_id。
/// 故进入搜索模式后筛选器被**禁用**并给出可见提示——不提示的话，用户会以为
/// 自己选的「近 30 天 / 只看失败」仍然生效，而列表其实是全量关键字命中。
class MyTurnsPage extends StatefulWidget {
  const MyTurnsPage({
    super.key,
    required this.fetch,
    this.search,
    this.onOpenTurn,
    this.title = '我的最近轮次',
    this.initialFilter = const MyTurnsFilter(),
    this.groupLabel,
    this.debounce = kMyTurnsSearchDebounce,
  });

  /// 拉取最近轮次。默认由 app 层注入 `ChatApi.listMyTurns`。
  final FetchMyTurns fetch;

  /// 按关键词搜索。null 时不渲染搜索框。
  final SearchMyTurns? search;

  /// 输入防抖时长（仅 [search] 非 null 时相关）。
  final Duration debounce;

  /// 点击某轮次时跳转到对应对话。
  ///
  /// ## 为什么带 [turnId]（issue #19）
  ///
  /// 只给 groupId 的话，点击只能跳到对话列表，用户**看不到「这一轮到底发生
  /// 了什么」**——而「最近轮次」页的存在意义正是回看某一轮。带上 turnId 后
  /// 调用方才能拉该轮的详情（`LoadTurnDetail`）。
  ///
  /// 签名与 `HabitsPage.onOpenTurn` / `HabitRunsPage.onOpenTurn` 对齐
  /// （`void Function(String groupId, String turnId)`）——两处语义相同，不应
  /// 各自一套。
  final void Function(String groupId, String turnId)? onOpenTurn;

  final String title;

  /// 初始筛选条件。
  ///
  /// 用于「从某个对话进来时预先只筛它」的场景（[groupId] 由调用方给出）；
  /// 默认值即「近 7 天、不筛来源/状态/对话」。
  final MyTurnsFilter initialFilter;

  /// [MyTurnsFilter.groupId] 的展示名（对话标题）。
  ///
  /// 为 null 时直接展示 id。与 `HabitsPage.groupTitleOf` 同一思路：页面不持有
  /// 网络客户端，标题由调用方从已有的列表里查。
  final String? groupLabel;

  @override
  State<MyTurnsPage> createState() => _MyTurnsPageState();
}

class _MyTurnsPageState extends State<MyTurnsPage> {
  List<ChatTurnSummary>? _items;
  Object? _error;
  bool _loading = true;

  /// 当前筛选条件（变更即重拉）。
  late MyTurnsFilter _filter = widget.initialFilter;

  final _queryController = TextEditingController();

  /// 防抖计时器。新输入到来时取消上一次。
  Timer? _debounceTimer;

  /// 当前生效的搜索词（trim 后）。非空即「搜索模式」。
  String _query = '';

  /// 已发出的搜索序号。
  ///
  /// ## 为什么需要它（而不只是取消 Timer）
  ///
  /// 防抖只挡住「还没发出去的」请求，挡不住**已在途**的响应：用户输入「报」→
  /// 请求 A 发出；300ms 后又输入「错」→ 请求 B 发出。若 A 比 B **晚**返回
  /// （网络抖动完全可能），A 的结果会覆盖 B 的——列表显示的是「报」的结果，
  /// 而输入框里是「报错」。
  ///
  /// 故每个请求带序号，响应回来时只接受**最新**的那个。与
  /// `SearchPage._requestSeq` 同一模式（那里有更详细的说明）。
  int _searchSeq = 0;

  List<ChatTurnSummary>? _searchItems;
  Object? _searchError;
  bool _searchLoading = false;

  bool get _isSearching => _query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final f = _filter;
    try {
      // `source` 要转成 wire 值（`toolAgent` → `tool_agent`），不能发枚举名。
      final items = await widget.fetch(
        days: f.days,
        source: f.source?.wire,
        status: f.status,
        groupId: f.groupId,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 切换筛选条件并重拉。
  void _onFilterChanged(MyTurnsFilter f) {
    if (f == _filter) return;
    setState(() => _filter = f);
    unawaited(_load());
  }

  // ==================== 搜索（issue #18） ====================

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    final query = value.trim();

    if (query.isEmpty) {
      if (_query.isEmpty) return; // 已经在列表模式，无变化。
      // 清空输入 = **退出搜索模式**，不是「搜空串」。
      //
      // 服务端对空 q 返回 400，但即使客户端能发也不该发：用户删光输入时看到的
      // 应该是回到列表，而不是一次多余的往返 + 上次残留的命中结果。
      setState(() {
        _query = '';
        _searchItems = null;
        _searchError = null;
        _searchLoading = false;
        // 序号自增，让在途响应失效——否则它回来会把列表模式又拽回搜索结果。
        _searchSeq++;
      });
      unawaited(_load());
      return;
    }

    // 同一个词不必重搜（`_searchItems != null` 说明已经搜过它了）。
    if (query == _query && _searchItems != null) return;
    setState(() => _query = query);
    _debounceTimer = Timer(widget.debounce, () => _runSearch(query));
  }

  /// 立即搜索（回车 / 点刷新），不等防抖。
  void _submitQuery() {
    _debounceTimer?.cancel();
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    _runSearch(query);
  }

  Future<void> _runSearch(String query) async {
    if (!mounted || widget.search == null) return;
    final seq = ++_searchSeq;
    setState(() {
      _searchLoading = true;
      _searchError = null;
    });

    try {
      final items = await widget.search!(query);
      // 丢弃过期响应（见 _searchSeq 说明）。
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searchItems = items;
        _searchLoading = false;
      });
    } on Object catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searchError = e;
        _searchLoading = false;
      });
    }
  }

  /// 刷新：搜索模式下重跑搜索，否则重拉列表。
  ///
  /// 若一律 `_load()`，用户在搜索模式点刷新会得到「列表刷新了但搜索结果没动」，
  /// 看起来像刷新坏了。
  void _refresh() {
    if (_isSearching) {
      unawaited(_runSearch(_query));
    } else {
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isSearching ? _searchLoading : _loading;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            key: const ValueKey('my-turns-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: busy ? null : _refresh,
          ),
        ],
      ),
      // 筛选条固定在列表之上（且**不受加载态影响**）：换条件时整页转圈会
      // 让筛选条一起消失，用户看不到自己选了什么。
      body: Column(
        children: [
          _buildFilterBar(context),
          const Divider(height: 1),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  /// 搜索框（未注入 [MyTurnsPage.search] 时返回空，不占位）。
  Widget _buildSearchField(BuildContext context) {
    if (widget.search == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.lg,
        SpbSpacing.sm,
        SpbSpacing.lg,
        0,
      ),
      child: TextField(
        key: const ValueKey('my-turns-search-field'),
        controller: _queryController,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: SpbSpacing.xl),
          hintText: '搜索轮次内容',
          border: const OutlineInputBorder(borderRadius: SpbRadius.inputAll),
          // 有内容时才给清除按钮（空框上挂一个 x 是噪音）。
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey('my-turns-search-clear'),
                  icon: const Icon(Icons.close, size: SpbSpacing.lg),
                  tooltip: '清除搜索',
                  onPressed: () {
                    _queryController.clear();
                    _onQueryChanged('');
                  },
                ),
        ),
        onChanged: _onQueryChanged,
        onSubmitted: (_) => _submitQuery(),
      ),
    );
  }

  /// 搜索模式下筛选器为何不可用的可见说明。
  Widget _buildSearchLockHint(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.lg,
        SpbSpacing.xs,
        SpbSpacing.lg,
        0,
      ),
      child: Row(
        key: const ValueKey('my-turns-search-hint'),
        children: [
          Icon(
            Icons.info_outline,
            size: SpbSpacing.lg,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: SpbSpacing.xs),
          Expanded(
            child: Text(
              // 说清「为什么灰了」：不是本端不支持，而是这个端点不接筛选参数。
              '搜索模式下筛选条件不生效（按关键词全量搜索）',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 筛选条：搜索框 + 时间窗 + 来源 + 状态（+ 对话，仅在被预筛时显示）。
  ///
  /// ## 搜索模式下筛选器全部禁用
  ///
  /// `/me/turns/search` 只认 `q` / `limit`（`user_turns.go` 的 `search`），
  /// 传 days/status/source/group_id 会被**静默忽略**。故搜索模式下把它们
  /// 置为 disabled 并给出 [MyTurnsPage] 文档里说的可见提示。
  Widget _buildFilterBar(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final scheme = theme.colorScheme;
    final f = _filter;
    final groupLabel = widget.groupLabel ?? f.groupId;
    // 搜索模式：筛选器只读（onSelected/onChanged 传 null 即 Material 的禁用态）。
    final locked = _isSearching;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.lg,
        SpbSpacing.sm,
        SpbSpacing.lg,
        SpbSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchField(context),
          if (locked) _buildSearchLockHint(context),
          Row(
            children: [
              Text('时间窗', style: textTheme.labelMedium),
              const SizedBox(width: SpbSpacing.sm),
              Expanded(
                child: Wrap(
                  spacing: SpbSpacing.xs,
                  children: [
                    for (final d in kMyTurnsDayOptions)
                      ChoiceChip(
                        key: ValueKey('my-turns-days-$d'),
                        label: Text('$d 天'),
                        selected: f.days == d,
                        onSelected: locked
                            ? null
                            : (_) => _onFilterChanged(f.copyWith(days: d)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: SpbSpacing.xs),
          Wrap(
            spacing: SpbSpacing.md,
            runSpacing: SpbSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _dropdown<TurnSource?>(
                context,
                key: const ValueKey('my-turns-source'),
                label: '来源',
                value: f.source,
                hint: '全部来源',
                items: [
                  const (value: null, label: '全部来源'),
                  for (final s in kMyTurnsSourceOptions)
                    (value: s, label: s.label),
                ],
                onChanged: locked
                    ? null
                    : (v) => _onFilterChanged(
                        v == null
                            ? f.copyWith(clearSource: true)
                            : f.copyWith(source: v),
                      ),
              ),
              _dropdown<String?>(
                context,
                key: const ValueKey('my-turns-status'),
                label: '状态',
                value: f.status,
                hint: '全部状态',
                items: [
                  const (value: null, label: '全部状态'),
                  for (final s in kMyTurnsStatusOptions)
                    (value: s.wire, label: s.label),
                ],
                onChanged: locked
                    ? null
                    : (v) => _onFilterChanged(
                        v == null
                            ? f.copyWith(clearStatus: true)
                            : f.copyWith(status: v),
                      ),
              ),
              // 对话筛选只在被调用方预筛时出现：本页没有「对话选择器」
              // （那需要先拉全部对话，属于对话列表页的职责）。
              // 搜索模式下也禁用：服务端 `/search` 不认 group_id。
              if (f.groupId != null)
                InputChip(
                  key: const ValueKey('my-turns-group-chip'),
                  label: Text('仅看：$groupLabel'),
                  onDeleted: locked
                      ? null
                      : () => _onFilterChanged(f.copyWith(clearGroup: true)),
                  deleteIcon: const Icon(Icons.close, size: SpbSpacing.lg),
                  deleteButtonTooltipMessage: '清除对话筛选',
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 带「全部」项的下拉（label 在左、下拉在右）。
  ///
  /// [onChanged] 为 null 时 DropdownButton 自会渲染为禁用态（不弹菜单）。
  Widget _dropdown<T>(
    BuildContext context, {
    required Key key,
    required String label,
    required T value,
    required String hint,
    required List<({T value, String label})> items,
    required ValueChanged<T?>? onChanged,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: textTheme.labelMedium),
        const SizedBox(width: SpbSpacing.xs),
        DropdownButton<T>(
          key: key,
          value: value,
          isDense: true,
          underline: const SizedBox.shrink(),
          hint: Text(hint),
          items: [
            for (final it in items)
              DropdownMenuItem<T>(value: it.value, child: Text(it.label)),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isSearching) {
      return _buildStateBody(
        context,
        loading: _searchLoading,
        error: _searchError,
        items: _searchItems,
        emptyIcon: Icons.search_off,
        // 搜索的空结果文案与列表不同：说清「这个关键词没命中」，而不是
        // 「最近没有轮次记录」（后者会让用户以为数据丢了）。
        emptyText: '没有匹配「$_query」的轮次',
        errorKey: 'my-turns-search-error',
        emptyKey: 'my-turns-search-empty',
        listKey: 'my-turns-search-list',
        onRetry: _refresh,
      );
    }
    return _buildStateBody(
      context,
      loading: _loading,
      error: _error,
      items: _items,
      emptyIcon: Icons.history_toggle_off,
      emptyText: '最近没有轮次记录',
      errorKey: 'my-turns-error',
      emptyKey: 'my-turns-empty',
      listKey: 'my-turns-list',
      onRetry: _refresh,
    );
  }

  /// 加载/错误/空/列表四态的公共渲染。
  ///
  /// 列表与搜索结果形状相同（都是 `List<ChatTurnSummary>`），只是 key 与
  /// 空态文案不同——抽出来避免两份几乎一样的代码各自漂移。
  Widget _buildStateBody(
    BuildContext context, {
    required bool loading,
    required Object? error,
    required List<ChatTurnSummary>? items,
    required IconData emptyIcon,
    required String emptyText,
    required String errorKey,
    required String emptyKey,
    required String listKey,
    required VoidCallback onRetry,
  }) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return Center(
        key: ValueKey(errorKey),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: SpbSpacing.xxl),
            const SizedBox(height: SpbSpacing.sm),
            Padding(
              padding: SpbSpacing.pagePadding,
              child: Text(
                '$error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      );
    }
    final list = items ?? const <ChatTurnSummary>[];
    if (list.isEmpty) {
      return Center(
        key: ValueKey(emptyKey),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              emptyIcon,
              size: SpbSpacing.xxxl,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: SpbSpacing.sm),
            Padding(
              padding: SpbSpacing.pagePadding,
              child: Text(emptyText, textAlign: TextAlign.center),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => onRetry(),
      child: ListView.separated(
        key: ValueKey(listKey),
        // 内容不足一屏时也能下拉刷新（对齐 GroupListPage 的先例）。
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: list.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _TurnTile(
          key: ValueKey('my-turn-${list[i].turnId}'),
          turn: list[i],
          onTap: widget.onOpenTurn == null
              ? null
              : () => widget.onOpenTurn!(list[i].groupId, list[i].turnId),
        ),
      ),
    );
  }
}

/// 单条轮次。
class _TurnTile extends StatelessWidget {
  const _TurnTile({super.key, required this.turn, this.onTap});

  final ChatTurnSummary turn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = turn;

    return ListTile(
      onTap: onTap,
      title: Text(
        // 输入摘要为空（异常载荷）时给出占位，避免空白行。
        t.inputPreview.isEmpty ? '（无输入）' : t.inputPreview,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: SpbSpacing.xxs),
        child: Wrap(
          spacing: SpbSpacing.sm,
          runSpacing: SpbSpacing.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _sourceBadge(scheme, theme.textTheme),
            _statusBadge(scheme, theme.textTheme),
            if (t.groupTitle != null && t.groupTitle!.isNotEmpty)
              Text(
                t.groupTitle!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              _formatTime(t.createdAt),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right, size: SpbSpacing.lg),
    );
  }

  Widget _sourceBadge(ColorScheme scheme, TextTheme textTheme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Text(turn.source.label, style: textTheme.labelSmall),
    );
  }

  Widget _statusBadge(ColorScheme scheme, TextTheme textTheme) {
    // ⚠️ 取消态是**英式** `cancelled`（服务端 `domain.go` 的 `TurnStatusCanceled`
    // 与 schema CHECK 都是英式）。只写美式 `canceled` 会永远落空，把已取消的
    // 轮次显示成「已完成」。两种拼写都接（防御历史/第三方写入）。
    final (Color bg, String label) = switch (turn.status) {
      'failed' => (scheme.errorContainer, '失败'),
      'cancelled' || 'canceled' => (scheme.surfaceContainerHighest, '已取消'),
      'running' || 'queued' => (scheme.tertiaryContainer, '进行中'),
      'pending' => (scheme.secondaryContainer, '待确认'),
      _ => (scheme.secondaryContainer, '已完成'),
    };
    // has_error 但 status 未标 failed：仍以失败色提示（服务端 error_count>0）。
    final effectiveBg = turn.hasError && turn.status != 'failed'
        ? scheme.errorContainer
        : bg;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Text(label, style: textTheme.labelSmall),
    );
  }

  /// 相对时间（近 24h 显示小时/分钟，否则显示日期）。
  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }
}

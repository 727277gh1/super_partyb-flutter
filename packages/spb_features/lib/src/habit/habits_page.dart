import 'dart:async';

import 'package:flutter/material.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import '../chat/habit_suggestion_card.dart';
import 'habit_edit_dialog.dart';
import 'habit_insights_bar.dart';
import 'habit_runs_page.dart';

/// 拉取建议列表。参数即服务端 `?status=` 的二分取值（见
/// [HabitSuggestionListFilter]）。
typedef LoadHabitSuggestions = Future<List<HabitSuggestion>> Function(
  HabitSuggestionListFilter filter,
);

/// 提交建议动作（accept / dismiss / snooze）。
///
/// `snooze` 仅在 `action == HabitSuggestionAction.snooze` 时有意义，且
/// **时刻由调用方算**（[HabitSnoozeOption.until] → UTC RFC3339）：服务端解析
/// 失败会静默回退冷却时长，格式错了用户只能发现「时间不对」。
typedef ResolveHabitSuggestion = Future<void> Function(
  HabitSuggestion suggestion,
  HabitSuggestionAction action, {
  HabitSnoozeOption? snooze,
});

/// 撤销处理（把建议退回待处理）。
typedef UnresolveHabitSuggestion = Future<void> Function(String suggestionId);

/// 拉取洞察摘要。参数是窗口天数。
typedef LoadHabitInsights = Future<HabitInsightsSummary> Function(int days);

/// 编辑规则（`PATCH /api/habits/:pattern_id`）。
///
/// 参数是**增量补丁**（只含改动字段），不是完整快照——见 [HabitPatch] 的类文档
/// （多发一个 `trigger_config` 就会让服务端重算 `next_fire_at`）。
/// 装配层实现即 `HabitApi.patchHabit`（逐字段映射补丁里的非 null 项）。
typedef EditHabit = Future<void> Function(UserHabit habit, HabitPatch patch);

/// 洞察摘要默认窗口（与服务端 `days` 默认值一致）。
const int kHabitInsightsDays = 30;

/// 习惯管理页：规则列表 + 启停 + 立即执行 + 执行历史。
///
/// ## 为什么用注入回调而不是收一个 `HabitApi`
///
/// 与 [PendingConfirmationsPage] 同一理由：本页只负责「展示 + 收集意图」，
/// 请求与错误翻译归调用方（app 装配层）。这样：
/// - widget test 里无需 HTTP mock 就能验证「什么条件下可点、点了传什么」；
/// - 「习惯功能整体关闭」时可以只不注入而不动页面代码。
///
/// ## 为什么列表与历史在同一页（三个 Tab）而不是三个页面
///
/// 用户看习惯时的真实问题是「这条规则到底有没有用」——需要**在规则旁边**看到
/// 它的执行记录。分成两个页面后，用户要在两处之间来回跳、还要自己把
/// `pattern_id` 对上号。
///
/// 但历史是**跨规则**的（服务端 `/api/habits/runs` 返回全部，含没有 pattern 的
/// 候选建议记录），故两个 Tab 各自的查询不同：规则 Tab 用 [loadHabits]，
/// 历史 Tab 用 [loadRuns]。
///
/// 第三个 Tab（建议收件箱）的存在理由是**可找回**：建议原本只在对话时间线里
/// 内联出现，用户当时没点、后来想找就翻不到；误点了忽略也无法撤销。故本页
/// 提供一个独立的待处理列表 + 撤销入口。
///
/// ## 与 [HabitRunsPage] 的分工
///
/// 本页的「执行记录」Tab 是**跨规则**的（`GET /api/habits/runs`，近 N 天、含候选
/// 记录），用于「最近发生了什么」。想回答「**这一条**规则跑过几次、都做了什么」
/// 则走规则条目的「执行记录」入口 → [HabitRunsPage]
/// （`GET /api/habits/:id/runs`，无时间窗、无其它规则干扰）。
class HabitsPage extends StatefulWidget {
  const HabitsPage({
    super.key,
    required this.loadHabits,
    required this.loadRuns,
    this.onTrigger,
    this.onPause,
    this.onResume,
    this.onArchive,
    this.onCreate,
    this.onEdit,
    this.onOpenTurn,
    this.loadSuggestions,
    this.resolveSuggestion,
    this.unresolveSuggestion,
    this.loadInsights,
    this.loadHabitRuns,
    required this.groupTitleOf,
  });

  /// 拉取规则列表（`GET /api/habits`）。
  final Future<List<UserHabit>> Function() loadHabits;

  /// 拉取执行历史（`GET /api/habits/runs`，服务端按 [HabitRunsFilter] 筛选）。
  final LoadHabitRunsHistory loadRuns;

  /// 立即执行一次（服务端要求 `active`，否则 409）。
  final Future<void> Function(UserHabit habit)? onTrigger;

  /// 暂停（仅 `active` → `paused`）。
  final Future<void> Function(UserHabit habit)? onPause;

  /// 恢复（仅 `paused` → `active`）。
  final Future<void> Function(UserHabit habit)? onResume;

  /// 归档（**终态**，无撤销端点）。
  final Future<void> Function(UserHabit habit)? onArchive;

  /// 新建规则。返回服务端建出的 pattern id（空串表示服务端未返回）。
  final Future<String> Function(HabitDraft draft)? onCreate;

  /// 编辑规则（`PATCH`，增量补丁）。为 null 时规则条目不显示「编辑」入口。
  final EditHabit? onEdit;

  /// 拉取**单条规则**的执行记录（`GET /api/habits/:pattern_id/runs`）。
  ///
  /// 为 null 时规则条目不显示「执行记录」入口。
  final LoadHabitRuns? loadHabitRuns;

  /// 跳到某条执行记录产生的对话。
  final void Function(String groupId, String turnId)? onOpenTurn;

  /// 拉取建议列表（`GET /api/chat/habit-suggestions`）。
  ///
  /// 为 null 时**不渲染「建议」Tab**（整个建议收件箱能力缺失）。
  final LoadHabitSuggestions? loadSuggestions;

  /// 提交建议动作。为 null 时建议 Tab 里的卡片只有只读展示（无按钮）。
  final ResolveHabitSuggestion? resolveSuggestion;

  /// 撤销处理。为 null 时已处理项不显示「撤销」入口。
  final UnresolveHabitSuggestion? unresolveSuggestion;

  /// 拉取洞察摘要（`GET /api/chat/habit-insights/summary`）。
  ///
  /// 为 null 时不渲染顶部摘要条。失败也只静默（摘要不该拖垮整页）。
  final LoadHabitInsights? loadInsights;

  /// 给定 groupId 返回对话标题（历史列表展示上下文用）。
  ///
  /// 必需而非可选：服务端 `/api/habits/runs` 只返回 `delivery_group_id`，
  /// 标题要由调用方从已有的 group 列表里查。不注入的话每条记录只能显示
  /// 一个 id，用户无法判断“这条到底跑在哪”。
  final String? Function(String groupId) groupTitleOf;

  @override
  State<HabitsPage> createState() => _HabitsPageState();
}

class _HabitsPageState extends State<HabitsPage> {
  List<UserHabit>? _habits;
  List<HabitRun>? _runs;

  /// 今日触发预算（`daily_budget`）；服务端未下发时为 null。
  HabitDailyBudget? _dailyBudget;

  /// 执行记录 Tab 的筛选条件（时间窗 + 触发原因）。
  ///
  /// 初值 30 天（[kHabitRunsDefaultDays]），不是服务端的 7 天默认——理由见该常量。
  HabitRunsFilter _runsFilter = const HabitRunsFilter();

  /// 仅执行记录 Tab 的加载态/错误（筛选切换时不整页转圈）。
  bool _runsLoading = false;
  Object? _runsError;

  Object? _error;
  bool _loading = true;

  /// 正在执行写操作的 pattern id（防重复点击）。
  final _busy = <String>{};

  // ---------- 建议收件箱 ----------

  List<HabitSuggestion>? _suggestions;
  Object? _suggestionsError;
  bool _suggestionsLoading = false;

  /// 「显示已处理」开关。对应服务端 `?status=dismissed`。
  ///
  /// ⚠️ 服务端 `ListDismissedHabitSuggestions` 的过滤条件是
  /// `user_feedback IS NOT NULL`（近 30 天）——**不只有 ignored**，已采纳与已
  /// 延后的也在里面。故文案是「显示已处理」而不是「显示已忽略」。
  bool _showResolved = false;

  /// 正在提交的建议 id（防重复点击；服务端 CAS 会挡，但连点会闪两次）。
  final _suggestionBusy = <String>{};

  // ---------- 洞察摘要 ----------

  HabitInsightsSummary? _insights;

  @override
  void initState() {
    super.initState();
    _load();
    // 建议与洞察**独立加载**：任一失败不该让整页变成错误页。
    if (widget.loadSuggestions != null) {
      unawaited(_loadSuggestions());
    }
    if (widget.loadInsights != null) {
      unawaited(_loadInsights());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 两个查询互不依赖，并发发出（历史页首屏也需要它）。
      final results = await Future.wait([
        widget.loadHabits(),
        widget.loadRuns(_runsFilter),
      ]);
      if (!mounted) return;
      setState(() {
        _habits = results[0] as List<UserHabit>;
        _applyRuns(results[1] as HabitRunsResult);
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

  /// 把一次 `GET /api/habits/runs` 的结果落到状态（列表 + 预算）。
  void _applyRuns(HabitRunsResult r) {
    _runs = r.items;
    _dailyBudget = r.dailyBudget;
    _runsError = null;
  }

  /// 筛选条件变化时**只重拉执行记录**。
  ///
  /// 不调 [_load]：那会连规则列表一起重拉（多一个无谓请求），且整页进入加载态，
  /// 用户会觉得「我只是换了个时间窗，怎么整个页面闪了一下」。
  ///
  /// 失败只影响该 Tab（`_runsError`），不把整页变成错误页——规则列表此时
  /// 仍然可用。
  Future<void> _loadRuns() async {
    setState(() {
      _runsLoading = true;
      _runsError = null;
    });
    try {
      final r = await widget.loadRuns(_runsFilter);
      if (!mounted) return;
      setState(() {
        _applyRuns(r);
        _runsLoading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _runsError = e;
        _runsLoading = false;
      });
    }
  }

  /// 切换筛选条件并重拉。
  void _onRunsFilterChanged(HabitRunsFilter f) {
    if (f == _runsFilter) return;
    setState(() => _runsFilter = f);
    unawaited(_loadRuns());
  }

  /// 拉取建议列表。
  ///
  /// 刷新语义与 [_load] 不同：这里**保留旧列表**直到新数据到达（`_suggestions
  /// != null` 时不清空），否则用户点「撤销」后列表会闪一下空态。
  Future<void> _loadSuggestions() async {
    final load = widget.loadSuggestions;
    if (load == null) return;
    setState(() {
      _suggestionsLoading = true;
      _suggestionsError = null;
    });
    try {
      final items = await load(
        _showResolved
            ? HabitSuggestionListFilter.dismissed
            : HabitSuggestionListFilter.pending,
      );
      if (!mounted) return;
      setState(() {
        _suggestions = items;
        _suggestionsLoading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _suggestionsError = e;
        _suggestionsLoading = false;
      });
    }
  }

  /// 拉取洞察摘要。失败静默（只记日志）——摘要不是页面的主内容。
  Future<void> _loadInsights() async {
    final load = widget.loadInsights;
    if (load == null) return;
    try {
      final insights = await load(kHabitInsightsDays);
      if (!mounted) return;
      setState(() => _insights = insights);
    } on Object catch (e) {
      SpbLog.warn('习惯洞察摘要加载失败', {'error': '$e'});
    }
  }

  /// 提交一个针对某条建议的写操作。
  ///
  /// 成功后**重新拉取列表**（而不是本地移除）：服务端的权威状态可能与本地
  /// 预期不同（如 accept 后列表里该条会消失，但「显示已处理」模式下它会变成
  /// 一条带「撤销」的已处理项）。
  Future<void> _runSuggestionAction(
    HabitSuggestion suggestion,
    Future<void> Function() action,
  ) async {
    if (_suggestionBusy.contains(suggestion.id)) return;
    setState(() => _suggestionBusy.add(suggestion.id));
    try {
      await action();
      if (!mounted) return;
      await _loadSuggestions();
    } on SpbError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_suggestionErrorText(e))));
      // 失败后刷新：多半是另一端已处理过（409），刷新让用户看到真实状态。
      await _loadSuggestions();
    } on Object catch (e, st) {
      // 非 SpbError（契约外的意外）。SnackBar 只说「操作失败，请重试」——
      // 底层原因**完全不可见**，故必须留痕（issue #45）。
      SpbLog.error(
        '处理习惯建议失败',
        error: e,
        stackTrace: st,
        fields: {'suggestion_id': suggestion.id},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    } finally {
      if (mounted) setState(() => _suggestionBusy.remove(suggestion.id));
    }
  }

  /// 把建议类错误翻成用户能理解的话。
  ///
  /// 409 是**预期内**的失败：服务端 resolve/unresolve 都走 CAS，两端同时操作
  /// 时后者必失败。必须同时给出「原因」（服务端文案，如「建议未被处理，无需恢复」）
  /// 与「怎么办」（刷新），否则用户会以为客户端坏了。
  static String _suggestionErrorText(SpbError e) {
    if (e is HttpError && e.isConflict) {
      final detail = e.message.isEmpty ? '' : '：${e.message}';
      return '建议已被别处处理，请刷新后重试$detail';
    }
    return _actionErrorText(e);
  }

  /// 执行一个针对某条规则的写操作，统一处理在途标记与失败提示。
  ///
  /// ## 为什么失败要弹提示而不是静默
  ///
  /// 这些操作都可能因**状态不符**失败（服务端 409：`仅 active 状态可触发`）。
  /// 静默失败会让用户看到「点了没反应」，然后反复点——而真正的原因是列表已经
  /// 过期（另一端改了状态）。弹提示 + 重新拉取才能让用户看到真实状态。
  Future<void> _runAction(
    UserHabit habit,
    Future<void> Function(UserHabit) action,
  ) async {
    if (_busy.contains(habit.id)) return;
    setState(() => _busy.add(habit.id));
    try {
      await action(habit);
      if (!mounted) return;
      await _load();
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(habit.id));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_actionErrorText(e))));
      // 失败后刷新：多半是状态已变（另一端操作过），刷新能让用户看到真实状态。
      await _load();
    } on Object catch (e, st) {
      // 同 `_handleSuggestion`：非 SpbError 的意外，SnackBar 之外无迹可寻。
      SpbLog.error(
        '习惯操作失败',
        error: e,
        stackTrace: st,
        fields: {'habit_id': habit.id},
      );
      if (!mounted) return;
      setState(() => _busy.remove(habit.id));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    } finally {
      if (mounted) setState(() => _busy.remove(habit.id));
    }
  }

  /// 把服务端错误翻成用户能理解的话。
  ///
  /// 409 是**预期内**的失败（状态不符），文案必须说明原因，否则用户会以为
  /// 客户端坏了。其余错误保留服务端原文（`HttpError.message` 已是 `{error}` 字段）。
  static String _actionErrorText(SpbError e) {
    if (e is HttpError) {
      // `SpbError.message` 是**非空** String（见 errors.dart），服务端 `{error}`
      // 字段在解析时已落进它，故无需再写 `?? 兜底`（那是死代码）。
      if (e.isConflict) return e.message.isEmpty ? '规则状态已变化，请刷新后重试' : e.message;
      if (e.isNotFound) return '规则已不存在';
      return e.message.isEmpty ? '操作失败（HTTP ${e.statusCode}）' : e.message;
    }
    return e.message.isEmpty ? '操作失败，请重试' : e.message;
  }

  Future<void> _handleCreate() async {
    final cb = widget.onCreate;
    if (cb == null) return;
    final draft = await showDialog<HabitDraft>(
      context: context,
      builder: (ctx) => const HabitEditorDialog(),
    );
    if (draft == null || !mounted) return;

    setState(() => _loading = true);
    try {
      await cb(draft);
      if (!mounted) return;
      await _load();
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_actionErrorText(e))));
    } on Object catch (e, st) {
      // 同 `_handleSuggestion`：非 SpbError 的意外。
      SpbLog.error('创建习惯失败', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('创建失败，请重试')));
    }
  }

  /// 编辑规则。
  ///
  /// ## 为什么先弹对话框再算补丁，而不是把 `habit` 直接交给对话框去提交
  ///
  /// 对话框只负责「回填 + 收集改动」，不知道怎么写请求（与页面其余部分同一分层
  /// 约定）。它返回 [HabitPatch]，由调用方经 [HabitsPage.onEdit] 发出去。
  ///
  /// ## 为什么「没改动」就不发请求
  ///
  /// 服务端 `update` 以现值为基准做部分更新，但 `trigger_config` **一旦出现**就
  /// 会重算 `next_fire_at`（把即将到期的触发推到下一个周期）。对话框已经用
  /// `HabitPatch.isEmpty` 禁用了保存按钮，这里是第二道防线（防将来有人把按钮
  /// 逻辑改坏）。
  Future<void> _handleEdit(UserHabit habit) async {
    final cb = widget.onEdit;
    if (cb == null) return;
    final patch = await HabitEditDialog.show(context, habit: habit);
    if (patch == null || patch.isEmpty || !mounted) return;
    await _runAction(habit, (h) => cb(h, patch));
  }

  /// 进入「按规则查看执行记录」。
  ///
  /// 用 `Navigator.push` 而非路由：它是本页的子视图（带返回按钮），不需要 URL
  /// 可寻址性，也不该出现在浏览器/桌面端的深链接里。
  void _openRuns(UserHabit habit) {
    final load = widget.loadHabitRuns;
    if (load == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HabitRunsPage(
          habit: habit,
          loadRuns: () => load(habit.id),
          onOpenTurn: widget.onOpenTurn,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Tab 数随注入能力变化：未注入建议回调时保持原有的两个 Tab（向后兼容）。
    final showSuggestions = widget.loadSuggestions != null;
    return DefaultTabController(
      length: showSuggestions ? 3 : 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('习惯'),
          actions: [
            if (widget.onCreate != null)
              IconButton(
                key: const ValueKey('habits-create'),
                icon: const Icon(Icons.add),
                tooltip: '新建习惯',
                onPressed: _loading ? null : _handleCreate,
              ),
            IconButton(
              key: const ValueKey('habits-refresh'),
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: _loading ? null : _refreshAll,
            ),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(text: '规则'),
              const Tab(text: '执行记录'),
              if (showSuggestions) const Tab(text: '建议'),
            ],
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  /// 「刷新」按钮：把三个来源都重拉一遍（含洞察）。
  ///
  /// 只刷 `_load()` 会让用户以为「刷新没生效」——他在「建议」Tab 上点了刷新，
  /// 建议列表却没动。
  Future<void> _refreshAll() async {
    await Future.wait([
      _load(),
      if (widget.loadSuggestions != null) _loadSuggestions(),
      if (widget.loadInsights != null) _loadInsights(),
    ]);
  }

  Widget _buildBody() {
    if (_loading && _habits == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = _error;
    if (err != null && _habits == null) {
      return HabitErrorView(
        error: err,
        onRetry: _load,
        retryKey: const ValueKey('habits-retry'),
      );
    }
    final insights = _insights;
    final tabs = TabBarView(
      children: [
        _buildHabits(),
        _buildRuns(),
        if (widget.loadSuggestions != null) _buildSuggestions(),
      ],
    );
    if (insights == null) return tabs;
    // 摘要条固定在 Tab 之上：它是「整页的总览」，跟着 Tab 滚动会让人以为它属于
    // 当前 Tab。
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SpbSpacing.lg,
            SpbSpacing.lg,
            SpbSpacing.lg,
            0,
          ),
          child: HabitInsightsBar(insights: insights),
        ),
        Expanded(child: tabs),
      ],
    );
  }

  /// 「建议」Tab：待处理收件箱 + 「显示已处理」开关。
  Widget _buildSuggestions() {
    final showResolved = _showResolved;
    final toggle = SwitchListTile(
      key: const ValueKey('habit-suggestions-show-resolved'),
      dense: true,
      value: showResolved,
      title: const Text('显示已处理'),
      // 说明范围，避免用户以为「已处理 = 我点过忽略的」。
      subtitle: const Text('含已采纳 / 已忽略 / 已延后（近 30 天）'),
      onChanged: _suggestionsLoading
          ? null
          : (v) {
              setState(() => _showResolved = v);
              unawaited(_loadSuggestions());
            },
    );

    final items = _suggestions;
    final err = _suggestionsError;
    Widget body;
    if (items == null && _suggestionsLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (items == null && err != null) {
      body = HabitErrorView(
        error: err,
        onRetry: _loadSuggestions,
        retryKey: const ValueKey('habits-retry'),
      );
    } else if (items == null || items.isEmpty) {
      body = HabitEmptyView(
        icon: showResolved ? Icons.history : Icons.auto_awesome,
        text: showResolved
            ? '近 30 天没有被处理过的建议。'
            : '没有待处理的建议。\nAgent 发现你的规律后会在这里（以及对话里）给出建议。',
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _loadSuggestions,
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: SpbSpacing.lg),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: SpbSpacing.sm),
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.lg),
            child: _buildSuggestionCard(items[i]),
          ),
        ),
      );
    }

    return Column(
      children: [
        toggle,
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );
  }

  Widget _buildSuggestionCard(HabitSuggestion s) {
    final resolve = widget.resolveSuggestion;
    final unresolve = widget.unresolveSuggestion;
    final busy = _suggestionBusy.contains(s.id);
    // 列表项没有 `editable_fields`（服务端 `habitRunToMap` 不下发），故
    // `HabitSuggestionItem.fromSuggestion` 产出的项 `canEdit == false`——
    // 卡片不会渲染「编辑并接受」。这不是漏接：编辑需要事件 payload 里的
    // 白名单，而收件箱走的是列表端点。
    return HabitSuggestionCard(
      suggestion: HabitSuggestionItem.fromSuggestion(s),
      busy: busy,
      onAccept: resolve == null
          ? null
          : () => _runSuggestionAction(
              s,
              () => resolve(s, HabitSuggestionAction.accept),
            ),
      onDismiss: resolve == null
          ? null
          : () => _runSuggestionAction(
              s,
              () => resolve(s, HabitSuggestionAction.dismiss),
            ),
      onSnooze: resolve == null
          ? null
          : (option) => _runSuggestionAction(
              s,
              () => resolve(s, HabitSuggestionAction.snooze, snooze: option),
            ),
      // 撤销只在已处理项上有意义（服务端 CAS 的 WHERE 要求 user_feedback
      // 非空），且只在注入时渲染。
      onUnresolve: unresolve == null
          ? null
          : () => _runSuggestionAction(s, () => unresolve(s.id)),
    );
  }

  Widget _buildHabits() {
    final habits = _habits ?? const <UserHabit>[];
    if (habits.isEmpty) {
      return const HabitEmptyView(
        icon: Icons.repeat,
        text: '还没有习惯。\nAgent 发现你的规律后会在这里（以及对话里）给出建议。',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: SpbSpacing.pagePadding,
        itemCount: habits.length,
        separatorBuilder: (_, _) => const SizedBox(height: SpbSpacing.sm),
        itemBuilder: (context, i) => _HabitTile(
          habit: habits[i],
          busy: _busy.contains(habits[i].id),
          onTrigger: widget.onTrigger == null
              ? null
              : (h) => _runAction(h, widget.onTrigger!),
          onPause: widget.onPause == null
              ? null
              : (h) => _runAction(h, widget.onPause!),
          onResume: widget.onResume == null
              ? null
              : (h) => _runAction(h, widget.onResume!),
          onArchive: widget.onArchive == null
              ? null
              : (h) => _confirmArchive(h),
          // 编辑对 archived 也允许：服务端 `update` 不校验状态（注释明写
          // 「对 archived 的 pattern 也能 PATCH 成功，只是它不会再被调度」）。
          // 而「已归档」的规则往往正需要改完再恢复——把它藏起来只会逼用户
          // 重建一条。
          onEdit: widget.onEdit == null ? null : _handleEdit,
          onOpenRuns: widget.loadHabitRuns == null ? null : _openRuns,
        ),
      ),
    );
  }

  /// 归档前二次确认。
  ///
  /// 归档是**终态**——服务端没有 unarchive 端点（`habits_full.go` 只有
  /// archive），误点后只能重新建一条。故必须确认。
  Future<void> _confirmArchive(UserHabit habit) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('归档这个习惯？'),
        content: Text('「${habit.topicKey}」归档后不再触发，且无法恢复（服务端不提供撤销）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('habit-archive-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _runAction(habit, widget.onArchive!);
  }

  Widget _buildRuns() {
    final budget = _dailyBudget;
    final filterBar = HabitRunsFilterBar(
      filter: _runsFilter,
      onChanged: _onRunsFilterChanged,
    );
    // 预算条与筛选条固定在列表之上：它们描述的是「整段历史」的上下文，
    // 跟着列表滚动会让人以为它们属于当前可见的那几条。
    Widget chrome(Widget body) => Column(
      children: [
        if (budget != null) HabitDailyBudgetBar(budget: budget),
        filterBar,
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );

    // 筛选重拉失败：只影响本 Tab，给出重试入口（保留旧列表会让人以为
    // 「筛选没生效」，清空又会以为「真的没记录」）。
    final runsErr = _runsError;
    if (runsErr != null) {
      return chrome(
        HabitErrorView(
          error: runsErr,
          onRetry: _loadRuns,
          retryKey: const ValueKey('habits-runs-retry'),
        ),
      );
    }

    final runs = _runs ?? const <HabitRun>[];
    if (_runsLoading && runs.isEmpty) {
      return chrome(const Center(child: CircularProgressIndicator()));
    }
    if (runs.isEmpty) {
      return chrome(
        const HabitEmptyView(icon: Icons.history, text: '还没有执行记录。'),
      );
    }
    return chrome(
      RefreshIndicator(
        onRefresh: _loadRuns,
        child: ListView.separated(
          padding: SpbSpacing.pagePadding,
          itemCount: runs.length,
          separatorBuilder: (_, _) => const Divider(height: SpbSpacing.xl),
          itemBuilder: (context, i) => HabitRunTile(
            run: runs[i],
            // 优先投递对话（实际执行处），回退来源对话。
            //
            // 两者在 due_rule 类里通常相同；但 `delivery_group_id` 为空而
            // `origin_group_id` 有值时（候选类记录），只看前者会丢掉上下文。
            groupTitle: _groupTitleFor(runs[i]),
            onOpenTurn: widget.onOpenTurn,
          ),
        ),
      ),
    );
  }

  String _groupTitleFor(HabitRun run) {
    final gid = run.deliveryGroupId ?? run.originGroupId;
    if (gid.isEmpty) return '';
    return widget.groupTitleOf(gid) ?? '';
  }
}

/// 规则卡片溢出菜单里的动作。
///
/// 用枚举而非两个独立按钮：菜单项的存在条件不同（各自看回调是否注入），
/// `PopupMenuButton.onSelected` 必须能区分选中的是哪一项。
enum _HabitMenuAction { edit, runs }

/// 一条规则卡片。
class _HabitTile extends StatelessWidget {
  const _HabitTile({
    required this.habit,
    required this.busy,
    this.onTrigger,
    this.onPause,
    this.onResume,
    this.onArchive,
    this.onEdit,
    this.onOpenRuns,
  });

  final UserHabit habit;
  final bool busy;
  final void Function(UserHabit)? onTrigger;
  final void Function(UserHabit)? onPause;
  final void Function(UserHabit)? onResume;
  final void Function(UserHabit)? onArchive;

  /// 打开编辑对话框（已由页面判定过注入）。
  final void Function(UserHabit)? onEdit;

  /// 进入该规则的执行记录页。
  final void Function(UserHabit)? onOpenRuns;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: ValueKey('habit-${habit.id}'),
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _topicLabel(habit.topicKey),
                    style: textTheme.titleSmall,
                  ),
                ),
                _StatusChip(status: habit.status),
                // 「编辑」与「执行记录」放进溢出菜单：两者都不是高频操作，
                // 与「立即执行/暂停/归档」平铺会挤满一行，且归档是终态、
                // 混在一起容易被误点。
                if (onEdit != null || onOpenRuns != null)
                  PopupMenuButton<_HabitMenuAction>(
                    key: ValueKey('habit-menu-${habit.id}'),
                    enabled: !busy,
                    tooltip: '更多',
                    onSelected: (action) => switch (action) {
                      _HabitMenuAction.edit => onEdit!(habit),
                      _HabitMenuAction.runs => onOpenRuns!(habit),
                    },
                    itemBuilder: (context) => [
                      if (onEdit != null)
                        const PopupMenuItem(
                          key: ValueKey('habit-edit'),
                          value: _HabitMenuAction.edit,
                          child: Text('编辑'),
                        ),
                      if (onOpenRuns != null)
                        const PopupMenuItem(
                          key: ValueKey('habit-runs'),
                          value: _HabitMenuAction.runs,
                          child: Text('执行记录'),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: SpbSpacing.xs),
            Text(
              habit.triggerConfig.summary,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: SpbSpacing.xxs),
            Text(
              _metaLine(habit),
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            Wrap(
              spacing: SpbSpacing.sm,
              runSpacing: SpbSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 每个按钮的存在条件由模型决定（`canTrigger` / `canPause` /
                // `canResume`），与页面的服务端状态机知识保持单一来源。
                if (onTrigger != null && habit.canTrigger)
                  TextButton.icon(
                    key: ValueKey('habit-trigger-${habit.id}'),
                    onPressed: busy ? null : () => onTrigger!(habit),
                    icon: const Icon(Icons.play_arrow, size: SpbSpacing.lg),
                    label: const Text('立即执行'),
                  ),
                if (onPause != null && habit.canPause)
                  TextButton.icon(
                    key: ValueKey('habit-pause-${habit.id}'),
                    onPressed: busy ? null : () => onPause!(habit),
                    icon: const Icon(Icons.pause, size: SpbSpacing.lg),
                    label: const Text('暂停'),
                  ),
                if (onResume != null && habit.canResume)
                  TextButton.icon(
                    key: ValueKey('habit-resume-${habit.id}'),
                    onPressed: busy ? null : () => onResume!(habit),
                    icon: const Icon(Icons.play_circle, size: SpbSpacing.lg),
                    label: const Text('恢复'),
                  ),
                if (onArchive != null && habit.canArchive)
                  TextButton(
                    key: ValueKey('habit-archive-${habit.id}'),
                    onPressed: busy ? null : () => onArchive!(habit),
                    child: const Text('归档'),
                  ),
                if (busy)
                  const SizedBox(
                    width: SpbSpacing.lg,
                    height: SpbSpacing.lg,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 与建议卡同策略：topic_key 是机器键，换分隔符展示，不编造中文名。
  static String _topicLabel(String topicKey) {
    if (topicKey.isEmpty) return '未命名习惯';
    return topicKey.replaceAll(RegExp(r'[._-]+'), ' ');
  }

  /// 副行：接受级别 · 来源 · 已执行次数 · 下次触发。
  static String _metaLine(UserHabit h) {
    final parts = <String>[
      h.acceptanceLevel.label,
      if (h.sourceType != HabitSourceType.unknown) h.sourceType.label,
      '已执行 ${h.triggerCount} 次',
    ];
    final next = h.nextFireAt;
    if (next != null && h.isActive) {
      parts.add('下次 ${_formatTime(next)}');
    }
    return parts.join(' · ');
  }

  static String _formatTime(DateTime t) {
    final local = t.toLocal();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${p2(local.hour)}:${p2(local.minute)}';
  }
}

/// 状态徽标。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final HabitPatternStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      HabitPatternStatus.active => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      HabitPatternStatus.paused => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      HabitPatternStatus.archived => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      _ => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: SpbRadius.cardAll),
      child: Text(
        status.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// 新建习惯的草稿（对话框产物）。
///
/// ## 为什么只暴露这两个字段
///
/// `POST /api/habits` 的必填项只有 `topic_key`；`acceptance_level` 有服务端默认
/// 值但语义关键（决定「自动跑」还是「只建议」），故必须让用户选。其余字段
/// （preferred_agent_id / delivery_group_id / prompt_contract）要么需要额外的
/// 列表数据，要么是高级用法——留空由服务端按默认处理，比让用户面对一堆
/// 不知道填什么的输入框更好。
class HabitDraft {
  const HabitDraft({
    required this.topicKey,
    required this.acceptanceLevel,
    this.triggerConfig,
  });

  final String topicKey;
  final HabitAcceptanceLevel acceptanceLevel;

  /// 触发条件。null = 不配时间（服务端回退 now+60min 兜底）。
  final HabitTriggerConfig? triggerConfig;
}

/// 新建习惯对话框。
class HabitEditorDialog extends StatefulWidget {
  const HabitEditorDialog({super.key});

  @override
  State<HabitEditorDialog> createState() => _HabitEditorDialogState();
}

class _HabitEditorDialogState extends State<HabitEditorDialog> {
  final _topicController = TextEditingController();
  HabitAcceptanceLevel _level = HabitAcceptanceLevel.suggestOnly;

  /// 小时/分钟。默认 9:00（与 webapp HabitPatternEditor 的默认一致）。
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);

  /// 星期（1=周一 … 7=周日）。空 = 每天。
  final _weekdays = <int>{};

  @override
  void dispose() {
    _topicController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _topicController.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('新建习惯'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('habit-editor-topic'),
              controller: _topicController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '主题',
                helperText: '如 weekly-report、preference.coffee',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: SpbSpacing.lg),
            Text('执行方式', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: SpbSpacing.xs),
            // RadioListTile.groupValue / onChanged 在 Flutter 3.32 起已弃用，
            // 改由祖先 RadioGroup 统一持有选中值与回调（与 settings_page 一致）。
            RadioGroup<HabitAcceptanceLevel>(
              groupValue: _level,
              onChanged: (v) => setState(() => _level = v ?? _level),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final l in HabitAcceptanceLevel.values)
                    if (l != HabitAcceptanceLevel.unknown)
                      RadioListTile<HabitAcceptanceLevel>(
                        key: ValueKey('habit-editor-level-${l.wire}'),
                        value: l,
                        title: Text(l.label),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                ],
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '触发时间',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                TextButton(
                  key: const ValueKey('habit-editor-time'),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: _time,
                    );
                    if (picked != null && mounted) {
                      setState(() => _time = picked);
                    }
                  },
                  child: Text(_time.format(context)),
                ),
              ],
            ),
            const SizedBox(height: SpbSpacing.xs),
            Text('重复（不选 = 每天）', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: SpbSpacing.xs),
            Wrap(
              spacing: SpbSpacing.xs,
              children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    key: ValueKey('habit-editor-weekday-$d'),
                    label: Text(
                      const ['一', '二', '三', '四', '五', '六', '日'][d - 1],
                    ),
                    selected: _weekdays.contains(d),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _weekdays.add(d);
                      } else {
                        _weekdays.remove(d);
                      }
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('habit-editor-save'),
          onPressed: valid
              ? () => Navigator.of(context).pop(
                  HabitDraft(
                    topicKey: _topicController.text.trim(),
                    acceptanceLevel: _level,
                    triggerConfig: HabitTriggerConfig(
                      triggerType: HabitTriggerType.timeBased,
                      time: HabitTimeTriggerConfig(
                        // 只填 times（服务端会据它同步顶层 hour/minute 影子字段）。
                        times: [
                          HabitTimeOfDay(
                            hour: _time.hour,
                            minute: _time.minute,
                          ),
                        ],
                        weekdays: _weekdays.toList()..sort(),
                      ),
                    ),
                  ),
                )
              : null,
          child: const Text('创建'),
        ),
      ],
    );
  }
}

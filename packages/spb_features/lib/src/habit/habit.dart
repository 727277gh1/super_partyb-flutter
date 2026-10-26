/// 习惯（habit）功能模块：规则管理页 + 建议卡。
///
/// ## 分层职责
///
/// 本目录只做**渲染与交互**：
/// - 消费 `spb_domain` 的归约结果（[HabitSuggestionItem]）；
/// - 调注入的回调（`loadHabits` / `onTrigger` / ...），**不持有** `HabitApi`。
///
/// HTTP 调用归 app 装配层。理由与 `chat/` 一致：页面无 API 依赖才能在 widget
/// test 里验证「什么条件下可点、点了传什么」，不需要 HTTP mock。
///
/// 建议卡本身在 `chat/` 下（[HabitSuggestionCard]）——它渲染在对话时间线里，
/// 与其余 item 组件同族；本目录放的是**独立页面**。
///
/// ## 三个页面/对话框
///
/// - [HabitsPage]：规则列表 / 执行记录 / 建议收件箱（三个 Tab）+ 洞察摘要条；
/// - [HabitEditDialog]：编辑既有规则（`PATCH /api/habits/:id`，只发改动字段）；
/// - [HabitRunsPage]：**按单条规则**看执行记录（`GET /api/habits/:id/runs`）。
library;

export 'habit_edit_dialog.dart';
export 'habit_insights_bar.dart';
export 'habit_runs_page.dart';
export 'habits_page.dart';

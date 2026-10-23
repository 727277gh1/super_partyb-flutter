/// 设置功能模块：同步目录 / 范围 / 过滤 / 本地清理与统计。
///
/// ## 分层职责
///
/// 本目录只做**渲染与表单交互**。**不含**以下内容（各自归属明确）：
/// - 持久化（偏好 + 目录绑定 + 状态重置事务）→ `spb_data` / app 装配层；
/// - 本地目录扫描与删除 → `spb_platform`（`local_prune.dart`）；
/// - 清理**计划**的规则（哪些目录有资格删）→ `spb_domain`（`sync_prune.dart`）；
/// - 对话列表 → `spb_api`（`ChatApi.listGroups`）；
/// - 桌面集成区块的显隐与文案 → [DesktopIntegrationInfo]（纯数据，
///   由 app 装配层从平台能力算好传入；页面不依赖 `spb_platform`）。
///
/// 页面全部依赖注入（`loadSettings` / `saveSettings` / `pickDirectory` /
/// `scanGroups` / `executePrune`），与 [LoginPage] 的 `onSignIn` 同一模式：
/// 因此可以在无数据库、无网络、无平台插件的 widget test 里完整验证。
///
/// ## 为什么保存是「整份提交」而非逐字段 setter
///
/// 「换目录必须重置同步状态」要求目录写入与状态清空**在同一事务**里完成。
/// 逐字段 setter 会让调用方（页面）负责保证这一点，而漏掉一步就会产生
/// 「目录已改、状态没清」的中间态。收成一个 [SaveSyncSettings] 入口后，
/// 事务边界由实现方决定，页面无从破坏。
library;

export 'notification_subscriptions_card.dart';
export 'settings_page.dart';
export 'user_preferences_card.dart';

/// 交付物同步功能模块：同步页（目录选择 / 触发同步 / 结果与失败展示）。
///
/// ## 分层职责
///
/// 本目录只做**渲染与交互**：展示同步目录、按钮、结果摘要与失败项。
///
/// **不含**以下内容（各自归属明确）：
/// - 同步策略（哪些下载/跳过/删除、状态推进）→ `spb_domain`
///   （`deliverable_sync.dart`）；
/// - 路径穿越防御与原子写入 → `spb_platform`（`file_sink.dart`）；
/// - UFS 列表与下载 → `spb_api`（`ufs_api.dart`）；
/// - 同步状态与配置持久化 → `spb_data`；
/// - 目录选择对话框 → `spb_platform`（`directory_picker.dart`）。
///
/// 页面的 [SyncPage.pickDirectory] / [SyncPage.runSync] 由 app 装配层注入，
/// 与 `LoginPage` 的 `onSignIn` 同一模式：页面不依赖平台插件，因此可以在
/// 无 GUI、无网络、无文件系统的 widget test 里完整验证。
library;

export 'sync_page.dart';

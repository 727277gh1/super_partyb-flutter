/// 冲突副本的路径构造（上行回传与下行覆盖共用）。
///
/// ## 为什么独立成文件
///
/// 两个方向都要物化 `_conflict/` 副本：
///
/// - 上行（`deliverable_upload_usecase.dart`）：用户版本传目标路径，agent 版本
///   落到 `_conflict/`；
/// - 下行（`deliverable_sync.dart`，issue #56）：远端变了而本地有未回传编辑，
///   覆盖前把本地版本落到 `_conflict/`。
///
/// 命名规则必须**完全一致**（否则用户的冲突副本会散在两个命名体系里，谁也
/// 说不清哪份是哪份），而它定义在 usecase 文件里时下行方向 import 会成环。
/// 故抽出这个纯函数文件。
library;

/// 冲突副本目录名。
///
/// 不在 groupsync 的 include globs 里 → 不被上传 UFS、不 emit 事件；但它在
/// workspace 里 → agent（容器挂载视图）能读到。
const String conflictDirName = '_conflict';

/// 构造冲突副本的组内路径：`_conflict/<RFC3339时间戳>-<原名>.conflict`。
///
/// ## 为什么 `.conflict` 后缀是必需的
///
/// groupsync 的 include globs 含 `**/*.spec.json`、`**/*.html`、`**/*.pdf`
/// 等**全目录**模式（`groupsync.go:89`）。若副本保持原名，
/// `_conflict/<ts>-foo.spec.json` 仍会命中白名单 → 被上传 UFS 并 emit
/// `agent.file.*`（归因错乱，且可能触发 IM 主动推送，额度仅 10 条/24h）。
/// 统一加 `.conflict` 后缀后，原名里的扩展名不再位于末尾，从而不命中任何
/// include glob。
///
/// ## 为什么时间戳要放进文件名
///
/// 同一文件可能冲突多次。只有原名的话第二次物化会**覆盖**第一次的副本，
/// 上一次的 agent 版本就丢了（UFS 的 file_versions 里还有，但用户/agent
/// 无从知道该去翻哪一版）。
String buildConflictPath(String groupRelPath, String rfc3339Timestamp) {
  final filename = conflictBasename(groupRelPath);
  // 冒号在 Windows 上是非法文件名字符，而冲突副本会落到用户的同步目录
  // （可能是 Windows）。替换成 '-'：仍是可读的时间戳，且不破坏排序。
  final safeTs = rfc3339Timestamp.replaceAll(':', '-');
  return '$conflictDirName/$safeTs-$filename.conflict';
}

/// 取路径最后一段（文件名）。
String conflictBasename(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// 「下载到本地」的落地相对路径 —— **纯函数**，两端共用同一套口径。
///
/// ## 解决什么问题
///
/// 客户端的「下载」有三条链路，此前**各自写了一份**落盘路径，且**都是平铺**：
///
/// | 链路 | 修复前的落盘位置 |
/// |---|---|
/// | 时间线内联卡（`_ensureAgentFileLocal` / `_downloadAgentFile`） | `downloads/agent/<文件名>` |
/// | 交付物面板（`downloadDeliverableProvider`） | `downloads/deliverables/<文件名>` |
/// | 交付物同步（`SyncEngine`） | `{用户选的目录}/{gid}/reports/a.md` ✅ |
///
/// 平铺带来三个真实后果：
///
/// 1. **互相覆盖**：每个 group 都有自己的 `README.md` / `reports/a.md`，
///    下载第二个 group 的同名文件会盖掉第一个（用户看到「下载完内容变了」）；
/// 2. **丢失目录结构**：`reports/a.md` 被压成 `a.md`，与面板里显示的树形路径
///    不一致，用户按面板的路径去找必然找不到；
/// 3. **分不清归属**：磁盘上没有任何信息说明这个文件属于哪个对话——而
///    「下载」的全部意义就是去文件管理器里找它。
///
/// 本文件把口径收敛到一处：`{groupId}/<group 内相对路径>`，与同步链路的
/// workspace 布局（`{gid}/reports/a.md`）**形状一致**——同一个文件无论走同步
/// 还是走手动下载，相对位置相同，用户只需记一种布局。
///
/// ## 为什么是纯函数（不碰磁盘 / 不拼绝对路径）
///
/// 「相对路径怎么算」是**正确性核心**（算错就写到别人的目录、或写出目标目录），
/// 必须能在无文件系统的环境里逐条断言。绝对路径（`getApplicationSupportDirectory`
/// 之类）留在各 app 的装配层——那是平台能力，纯 Dart 包拿不到。
///
/// ## 路径穿越防御
///
/// 两段的来源都是**服务端可控输入**（UFS 的 `path` / 事件的 `relative_path`），
/// 故逐段过 [isValidPathSegment]（空段 / `.` / `..` / `\` / NUL 一律拒绝）。
/// 不合法时**退化为单文件名**而不是报错：文件还是能拿到，只是没有目录结构；
/// 而报错会让「点下载」在一个路径异常的文件上永久失败。
library;

import 'package:spb_models/spb_models.dart';

import 'conversation_item.dart';
import 'sync_path.dart';

/// 交付物（`UfsFileEntry`）在下载目录内的相对路径：`{groupId}/<group 内相对路径>`。
///
/// 由 UFS 物化路径反推：`/workspace/groups/{gid}/reports/a.md/`
/// → `{gid}/reports/a.md`。
///
/// ## 为什么从 `path` 反推 groupId，而不是由调用方另传一个
///
/// 「这个文件属于哪个 group」在 `UfsFileEntry.path` 里已经是权威的。另传一个
/// `groupId` 参数就有两个来源——面板的 `groupId` 与文件的实际路径不一致时
/// （切 group 的瞬间、或服务端返回了别的 group 的文件）以谁为准无解，而
/// 错的那一方会让文件落进**别的对话的目录**。
///
/// ## 两种退化（都不报错，且都不会逃出下载目录）
///
/// - 路径不在 `/workspace/groups/` 下（非交付物）→ 省略 `{groupId}`，只留文件名；
/// - 某一段非法（穿越面）→ 同上。
String deliverableDownloadRelPath(UfsFileEntry file) {
  final fallback = _safeBasename(
    file.name.isNotEmpty ? file.name : file.path,
    orElse: file.id,
  );

  if (!file.path.startsWith(workspaceGroupsPrefix)) return fallback;
  final rest = _stripSlashes(file.path.substring(workspaceGroupsPrefix.length));
  if (rest.isEmpty) return fallback;

  final segments = rest.split('/');
  // 只有 groupId 没有后续路径 → 是 group 根目录，不是文件。
  if (segments.length < 2) return fallback;
  if (!segments.every(isValidPathSegment)) return fallback;
  return segments.join('/');
}

/// 时间线交付物（`AgentFileItem`）在下载目录内的相对路径。
///
/// [groupId] 由调用方给（事件载荷里没有 groupId，时间线卡片只带
/// `relative_path`），其余规则同 [deliverableDownloadRelPath]。
///
/// ## 为什么 `relativePath` 已经是「group 内相对路径」
///
/// 归约器把它归一化过（`\\` → `/`、折叠重复斜杠、去首尾斜杠），且服务端发的是
/// group 内相对路径（形如 `reports/a.md`），不是 UFS 绝对路径。故这里只需
/// 段级校验 + 拼 groupId，**不要**再剥 `/workspace/groups/{gid}/` 前缀
/// （剥了反而会把合法的 `workspace/...` 相对路径削掉一截）。
String agentFileDownloadRelPath(AgentFileItem file, String groupId) {
  final fallback = _safeBasename(
    file.fileName.isEmpty ? 'agent-file' : file.fileName,
    orElse: file.id,
  );
  final gid = groupId.contains('/') || groupId.contains('\\')
      ? null
      : (isValidPathSegment(groupId) ? groupId : null);

  final rel = _stripSlashes(file.relativePath.replaceAll('\\', '/'));
  final segments = rel.isEmpty
      ? const <String>[]
      : rel.split('/').where((s) => s.isNotEmpty).toList();
  final safe = segments.isNotEmpty && segments.every(isValidPathSegment)
      ? segments
      : <String>[fallback];

  return gid == null ? safe.join('/') : '$gid/${safe.join('/')}';
}

/// 取最后一段作文件名，并保证结果可用（空 / 非法时回落到 [orElse]）。
///
/// `p.basename` 在纯 Dart 包里可用，但这里手写更直白：只需要按 `/` 与 `\`
/// 两种分隔符切最后一段，而多引一个包只为一个 `basename` 不值得。
String _safeBasename(String path, {required String orElse}) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == '/' || path[end - 1] == '\\')) {
    end--;
  }
  if (end == 0) return orElse;
  final trimmed = path.substring(0, end);
  final idx = trimmed.lastIndexOf(RegExp(r'[/\\]'));
  final name = idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
  if (name.isEmpty || !isValidPathSegment(name)) return orElse;
  return name;
}

String _stripSlashes(String s) {
  var start = 0;
  var end = s.length;
  while (start < end && s[start] == '/') {
    start++;
  }
  while (end > start && s[end - 1] == '/') {
    end--;
  }
  return s.substring(start, end);
}

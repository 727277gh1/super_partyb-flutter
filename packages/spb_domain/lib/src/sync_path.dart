/// UFS 绝对路径 → 本地相对路径的映射，含**路径穿越防御**。
///
/// UFS 里 group 交付物的路径形如
/// `/workspace/groups/{group_id}/reports/xxx.md`，落到用户所选目录时应剥掉
/// `/workspace/groups/{group_id}/` 前缀，变成 `{所选目录}/reports/xxx.md`。
///
/// 对齐 `super_partyb/apps/desktop/src-tauri/src/sync/path.rs`。
///
/// ## 为什么防御逻辑必须在 domain（而不是留给落盘实现）
///
/// 同步器会**按远端返回的路径名写本地文件**。远端路径是服务端可控的输入，
/// 一旦其中出现 `..` 或绝对路径，就能让写入逃出用户所选目录（覆盖
/// `~/.ssh/authorized_keys` 之类）。因此校验必须在**生成计划时**完成：
/// 非法路径根本不进入动作列表，落盘层拿到的 `relPath` 已被证明安全。
/// 落盘层仍应做一次兜底校验（纵深防御），但正确性不依赖它。
library;

/// UFS 中 group 工作区的固定前缀。
const String workspaceGroupsPrefix = '/workspace/groups/';

/// 判断单个路径段是否合法。
///
/// - 空段（`a//b`）会让路径语义含糊，拒绝；
/// - `.` / `..` 是穿越面；
/// - `\` 在 Windows 上是**目录分隔符**，放过去等于绕过段级校验；
/// - NUL 会截断底层系统调用的路径。
bool isValidPathSegment(String segment) =>
    segment.isNotEmpty &&
    segment != '.' &&
    segment != '..' &&
    !segment.contains('\\') &&
    !segment.contains('\u0000');

/// 从 UFS 绝对路径提取 group 内的相对路径。
///
/// 返回 null 表示「不属于该 group 或不参与同步」，具体情形：
/// - 路径不在 `/workspace/groups/{groupId}/` 子树下；
/// - 相对部分为空（即 group 根目录自身，不是文件）；
/// - 含空路径段、`.`、`..`、`\` 或 NUL。
///
/// ## 尾斜杠必须剥掉（实测）
///
/// UFS 的物化路径对**文件也带尾斜杠**（`buildMaterializedPath` 无条件拼
/// `name + '/'`，见 `unified-file-service/internal/service/file.go`），
/// 实测 `/workspace/groups/{gid}/README.md/`。不剥尾斜杠的话尾段为空，
/// **全部文件**都会被判为非法路径而跳过——同步「成功」但一个文件都没落盘。
///
/// 返回值不含前导 `/`，各段以 `/` 分隔，可直接拼到目标目录下。
String? groupRelativePath(String ufsPath, String groupId) {
  // 空 groupId 会让前缀退化成 `/workspace/groups//`，语义不成立。
  if (groupId.isEmpty) return null;
  final prefix = '$workspaceGroupsPrefix$groupId/';
  if (!ufsPath.startsWith(prefix)) return null;
  final rest = _stripTrailingSlashes(ufsPath.substring(prefix.length));
  if (rest.isEmpty) return null;
  if (!rest.split('/').every(isValidPathSegment)) return null;
  return rest;
}

/// 从 UFS 绝对路径提取**整个 workspace** 的相对路径（含 groupId 段）。
///
/// 用于「同步全部 group 到同一个本地目录」：
/// `/workspace/groups/{gid}/reports/a.md/` → `{gid}/reports/a.md`。
///
/// ## 为什么要保留 groupId 段
///
/// 不同 group 各有自己的 `README.md`。若剥掉 groupId，它们会落到同一个
/// 路径上互相覆盖——用户看到的是「文件内容莫名变了」。
///
/// 返回 null 的情形与 [groupRelativePath] 一致，另加：
/// - 路径恰好是某个 group 根目录（`/workspace/groups/{gid}/`）——它是目录；
/// - 第一段（groupId）本身非法。
String? workspaceRelativePath(String ufsPath) {
  if (!ufsPath.startsWith(workspaceGroupsPrefix)) return null;
  final rest = _stripTrailingSlashes(
    ufsPath.substring(workspaceGroupsPrefix.length),
  );
  if (rest.isEmpty) return null;

  final segments = rest.split('/');
  if (!isValidPathSegment(segments.first)) return null;
  // 只有 groupId 没有后续路径 → group 根目录自身，不是文件。
  if (segments.length < 2) return null;
  if (!segments.skip(1).every(isValidPathSegment)) return null;
  return rest;
}

String _stripTrailingSlashes(String s) {
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x2F) {
    end--;
  }
  return s.substring(0, end);
}

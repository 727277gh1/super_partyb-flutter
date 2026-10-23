/// 「这个交付物是否已经同步到本地、落在哪个相对路径」——**纯函数**。
///
/// ## 解决什么问题
///
/// 交付物侧边栏的「打开 / 定位」原先只能对**手动下载过**的文件生效：用户即便
/// 早已把整个 workspace 同步到本地目录，仍要在面板里再下载一次才能打开。
/// 本函数把「同步状态」与「UFS 路径」拼起来，回答「本地有没有这一份、在哪」。
///
/// ## 为什么必须是纯函数（不碰磁盘）
///
/// 它要能在无文件系统的环境里单测，且**不能**用 `File.exists` 代替状态查询：
///
/// - `SyncState.files` 是「同步器认为已经落盘」的记录，查询是 O(1)；
/// - 逐文件 `exists` 在侧边栏一次要查上百个路径，是同步 IO；
/// - 更重要的是**语义不同**：本函数回答的是「同步索引里有没有」，而
///   「磁盘上还在不在」由打开失败时的兜底处理（用户可能手动删了）。
///
/// 与 `sync_path.dart` 的 [groupRelativePath] / [workspaceRelativePath] 共用
/// 同一套路径映射与穿越防御——这是**关键**：若这里用另一套规则算相对路径，
/// 算出来的路径与同步器实际落盘的位置就会不一致，表现为「索引里有记录、但
/// 打开的是一个不存在的路径」。
library;

import 'sync_path.dart';
import 'sync_state.dart';

/// 同步目录的落盘布局。
///
/// 由用户选择的**同步范围**决定，且必须与 `syncStateKeyFor` 选出的状态键配对
/// 使用——布局、状态键、相对路径三者是一个整体，错配就会读错文件。
enum DeliverableSyncLayout {
  /// 「全部 group」或「选中若干 group」：保留 `{groupId}/` 分层。
  ///
  /// 对应状态键 [workspaceStateKey]，相对路径形如
  /// `{groupId}/reports/a.md`。
  workspace,

  /// 单个 group：剥掉前缀，本地直接是该 group 的内容。
  ///
  /// 对应状态键 = `groupId` 本身，相对路径形如 `reports/a.md`。
  singleGroup,
}

/// 把 UFS 交付物路径解析为**同步目录内的相对路径**；未同步或非法返回 null。
///
/// [state] 必须是**与 [layout] 匹配**的状态键下的状态：
///
/// | [layout] | 状态键 | 相对路径形态 |
/// |---|---|---|
/// | [DeliverableSyncLayout.workspace] | [workspaceStateKey] | `{groupId}/reports/a.md` |
/// | [DeliverableSyncLayout.singleGroup] | `groupId` | `reports/a.md` |
///
/// ## ⚠️ 布局与状态键必须配对（否则是**假阳性**）
///
/// 本函数只看「相对路径在不在 `state.files` 里」，它无法知道这份状态是哪种
/// 布局。错配的后果不是「查不到」而是**查错**：
///
/// - 把 workspace 状态喂给 [DeliverableSyncLayout.singleGroup]：两个 group 里
///   同名的 `README.md` 会互相命中，B 组的文件被报告为「已同步」并指向 A 组
///   的内容；
/// - 反向同理。
///
/// 故调用方必须按上表配对（状态键用 `syncStateKeyFor(scope)` 取）。
///
/// ## 返回值是**相对**路径（不是绝对路径）
///
/// 本包是纯 Dart（无 `dart:io`），不能依赖平台的路径分隔符与根目录概念。
/// 拼接交给调用方（桌面端用 `p.join(localRoot, rel)`，Windows 上才会得到
/// 正确的反斜杠）。这样「映射规则」与「平台细节」各归其位。
///
/// 返回 null 的情形：
/// - [groupId] 为空（前缀会退化成 `/workspace/groups//`，语义不成立）；
/// - [ufsPath] 不在该 group 的子树下；
/// - 路径含 `..` / `.` / 空段 / `\` / NUL，或是 group 根目录自身；
/// - 该相对路径**不在** [state] 的已同步记录里（→ 尚未同步）。
String? resolveLocalDeliverablePath(
  SyncState state,
  String groupId,
  String ufsPath, {
  DeliverableSyncLayout layout = DeliverableSyncLayout.workspace,
}) {
  // 复用同步器的路径映射：同一个函数既做穿越防御，又保证「算出来的相对路径
  // 与同步器实际落盘的位置」完全一致（见库文档）。
  final rel = switch (layout) {
    DeliverableSyncLayout.workspace => _workspaceRel(ufsPath, groupId),
    DeliverableSyncLayout.singleGroup => groupRelativePath(ufsPath, groupId),
  };
  if (rel == null) return null;

  // 只认「同步索引里有记录」。这里刻意**不**判断记录是否与远端一致
  // （etag/size）：问题是「本地有没有这一份可以打开的文件」，而不是
  // 「它是不是最新的」。内容过期是同步器下一轮要解决的事，不该让用户
  // 现在打不开一个本地存在的文件。
  if (!state.contains(rel)) return null;

  return rel;
}

/// workspace 布局的相对路径，并**额外**确认它确实属于 [groupId]。
///
/// ## 为什么不能只靠 [workspaceRelativePath]
///
/// 它返回的是 `{groupId}/{rest}`，已经把 groupId 编进了路径——但它是从
/// [ufsPath] 里**读出来**的，不校验调用方传的 [groupId] 是否一致。若调用方
/// 把 groupId 传成了另一个值（例如用了过期的 widget 状态），返回的路径仍会
/// 是「ufsPath 所属 group」的路径，于是面板会打开**另一个对话**的文件。
///
/// 显式比对让这种错配变成「查不到」（返回 null），而不是静默打开错文件。
String? _workspaceRel(String ufsPath, String groupId) {
  if (groupId.isEmpty) return null;
  final rel = workspaceRelativePath(ufsPath);
  if (rel == null) return null;
  // rel 形如 `{gid}/rest`；首段必须正是调用方声明的 groupId。
  if (!rel.startsWith('$groupId/')) return null;
  return rel;
}

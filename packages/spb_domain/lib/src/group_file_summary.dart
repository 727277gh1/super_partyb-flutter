/// 对话列表卡片的「本地交付物统计」聚合（纯函数，无 IO、无 Flutter）。
///
/// ## 它解决什么问题
///
/// 对话列表（`GroupListPage`）此前只有标题与相对时间。用户问得最多的
/// 「这个对话产出了什么、同步到哪了」在列表上不可见——而答案**就在本地**：
/// 交付物同步的状态库（`SyncStateStore`）按 group 记录了每个已落盘文件的
/// 相对路径、体积与同步时间。
///
/// 本文件把「两个状态键的原始记录」聚合成「一个 group 一行统计」：
/// `N 个文件 · 3.4 MB · 3 天前同步`。
///
/// ## 为什么是纯函数
///
/// 与 [resolveLocalDeliverablePath] 同一取向：聚合规则（布局判定、机器产物
/// 过滤、去重）必须能在无文件系统的 CI 里逐条验证；读状态库是装配层的职责
/// （见两端 `providers.dart` 的同名 provider）。
///
/// ## 数据来源与两种布局（对齐 `DeliverableSyncLayout`）
///
/// | 用户选的同步范围 | 状态键 | 记录的相对路径形态 |
/// |---|---|---|
/// | 全部 / 选中若干 / 定向同步 | `__workspace__` | `{groupId}/reports/a.md` |
/// | 单个 group（程序化产出） | `groupId` | `reports/a.md` |
///
/// 查询时无法从库里反推用户当时用的是哪种范围，故两种都查（与桌面端
/// `DeliverableLocalIndex.relativePathOf` 同一策略），命中哪个用哪个；
/// 同一 group 在两个键下都有记录时**合并**（理论上只发生在「先定向、后全量」
/// 的混用场景，去重后语义不变——见 [groupFileSummaryOf]）。
library;

import 'deliverable_sync.dart' show isMachineGenerated;
import 'sync_state.dart';

/// 一个 group 的本地已同步交付物统计。
class GroupFileSummary {
  const GroupFileSummary({
    required this.fileCount,
    required this.totalBytes,
    this.lastSyncedAt,
  });

  /// 已同步的（可见）文件数。
  ///
  /// 已剔除机器产物（TTS 语音 / `.archive` / `_attachments`，判据与同步器
  /// 同一套 [isMachineGenerated]）——列表展示的是「交付物」，不是磁盘占用。
  final int fileCount;

  /// 上述文件的字节总和。
  final int totalBytes;

  /// 最近一次同步到本 group 的时间（取各文件记录 `updated_at` 的最大值）。
  ///
  /// null 表示记录里没有可用时间（旧版本写入的状态没有该字段）。
  final DateTime? lastSyncedAt;

  bool get isEmpty => fileCount == 0;

  @override
  bool operator ==(Object other) =>
      other is GroupFileSummary &&
      other.fileCount == fileCount &&
      other.totalBytes == totalBytes &&
      other.lastSyncedAt == lastSyncedAt;

  @override
  int get hashCode => Object.hash(fileCount, totalBytes, lastSyncedAt);

  @override
  String toString() =>
      'GroupFileSummary(files: $fileCount, bytes: $totalBytes, '
      'syncedAt: $lastSyncedAt)';
}

/// 聚合 [groupId] 的本地交付物统计；没有可展示内容时返回 null。
///
/// 返回 null 的情形（**都是「不显示文件条」**，调用方无需区分）：
/// - [groupId] 为空；
/// - 两个状态键下都没有该 group 的记录（从未同步 / 范围未含它）；
/// - 记录全被过滤（只有机器产物，或 group 根目录行）。
///
/// ## 为什么「同步过但 0 个可见文件」也返回 null
///
/// 「0 个文件 · 0 B」对用户没有信息量（它的常见成因是同步器把媒体全部
/// 过滤了），显示出来反而像出错。有内容才显示。
///
/// ## 为什么不校验本地目录绑定（`boundLocalRoot`）
///
/// 本统计只回答「同步器记录里有什么」。目录绑定影响的是「文件在哪」
/// （拼绝对路径打开文件时才需要，见桌面端 `DeliverableLocalIndex`）；
/// 记录存在即视为已同步——用户手动删了本地文件属于打开失败时的兜底，
/// 不影响统计展示。
GroupFileSummary? groupFileSummaryOf({
  required String groupId,
  required SyncState workspaceState,
  SyncState? singleGroupState,
}) {
  if (groupId.isEmpty) return null;

  // group 内相对路径 → 记录。键去重：同一文件先经定向、后经全量同步会在
  // 两个键里各留一条（指向同一份内容），按 group 内路径合并即可。
  final files = <String, SyncedFile>{};

  // workspace 布局：记录带 `{groupId}/` 前缀。
  final prefix = '$groupId/';
  workspaceState.files.forEach((relPath, file) {
    if (!relPath.startsWith(prefix)) return;
    _collect(files, relPath.substring(prefix.length), file);
  });

  // 单 group 布局：记录本身就是 group 内路径。
  final single = singleGroupState;
  if (single != null) {
    single.files.forEach((relPath, file) => _collect(files, relPath, file));
  }

  if (files.isEmpty) return null;

  var bytes = 0;
  DateTime? lastSyncedAt;
  for (final file in files.values) {
    bytes += file.size;
    final raw = file.updatedAt;
    final at = raw == null ? null : DateTime.tryParse(raw)?.toLocal();
    if (at != null && (lastSyncedAt == null || at.isAfter(lastSyncedAt))) {
      lastSyncedAt = at;
    }
  }
  return GroupFileSummary(
    fileCount: files.length,
    totalBytes: bytes,
    lastSyncedAt: lastSyncedAt,
  );
}

/// 收集一条记录；空路径与机器产物跳过。
///
/// [inner] 必须是 **group 内**相对路径——[isMachineGenerated] 的 TTS 判据
/// （`reports/tts/`）锚定在开头，喂给它带 `{gid}/` 前缀的路径永远不命中
/// （见该函数文档的同名教训）。两个布局在这里已各自剥掉前缀，故安全。
void _collect(Map<String, SyncedFile> out, String inner, SyncedFile file) {
  if (inner.isEmpty) return;
  if (isMachineGenerated(inner)) return;
  out[inner] = file;
}

/// 人类可读的字节大小（`B` / `KB` / `MB` / `GB`，一位小数）。
///
/// 放在 domain 而不是页面：`GroupFileSummary` 的展示（列表卡片）与
/// `agent_file_card.dart` 的私有 `_formatBytes` 是同一需求，先在这里提供
/// 一份公共实现；既有私有副本不动（避免扩大改动面），后续重构再收拢。
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

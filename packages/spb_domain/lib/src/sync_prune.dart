/// 本地同步目录的清理计划与统计（**纯逻辑**，不碰磁盘）。
///
/// ## 为什么需要清理
///
/// 同步是「只增不减」的：group 越来越多、历史交付物越积越多。用户迟早需要
/// 一个「把不要的删掉」的入口。本文件提供**可预览**的清理计划：先算出要删
/// 什么，再由上层确认后执行。
///
/// 对齐 `super_partyb/apps/desktop/src-tauri/src/sync/prune.rs`。
///
/// ## 安全约束（这是删除逻辑，必须保守）
///
/// 同步目录是**用户自己的目录**，里面可能有他自己的文件。因此：
///
/// 1. **只认 group_id 形状的目录名**（[isGroupId]：32 位小写十六进制）——
///    这是唯一的准入门槛，刻意严格。它同时天然排除了 `.git`、`node_modules`、
///    `README.md` 等一切非同步产物。
/// 2. **不跟随符号链接**——一个名为 group_id 的软链可能指向 `~`。类型判定在
///    扫描层（`spb_platform`）用 `followLinks: false` 完成，本层的
///    [LocalGroupStats] 只接受已通过校验的条目。
/// 3. **只删到 group 目录这一层**，不递归删除任意深度的路径。
library;

/// 清理结果。
///
/// ## 为什么定义在 domain 而不是执行层（`spb_platform/local_prune.dart`）
///
/// 它是纯数据（删除计数 + 失败原因），与 [LocalGroupStats] / [PrunePlan] 同构，
/// 且被设置页的 `ExecutePrune` 类型直接引用。若留在平台层，设置页为了这一个
/// 类型就得 import `spb_platform`（拖带窗口/托盘/快捷键插件）。
/// 执行层从本包 re-export，既有调用方不受影响。
class PruneOutcome {
  const PruneOutcome({required this.deleted, required this.failed});

  /// 成功删除的 group 数。
  final int deleted;

  /// 失败项：groupId → 原因。
  final Map<String, String> failed;

  bool get hasFailures => failed.isNotEmpty;
}

/// 本地一个 group 目录的概况（由扫描层产出，已通过形状与软链校验）。
class LocalGroupStats {
  const LocalGroupStats({
    required this.groupId,
    required this.fileCount,
    required this.totalBytes,
    this.newestMtime,
  });

  /// group_id（目录名，已校验为 32 位小写十六进制）。
  final String groupId;

  /// 文件数（递归统计）。
  final int fileCount;

  /// 总字节数（递归统计）。
  final int totalBytes;

  /// 目录内最新文件的 mtime（Unix 秒）；**空目录为 null**。
  final int? newestMtime;

  @override
  bool operator ==(Object other) =>
      other is LocalGroupStats &&
      other.groupId == groupId &&
      other.fileCount == fileCount &&
      other.totalBytes == totalBytes &&
      other.newestMtime == newestMtime;

  @override
  int get hashCode => Object.hash(groupId, fileCount, totalBytes, newestMtime);

  @override
  String toString() =>
      'LocalGroupStats($groupId, $fileCount 个文件, ${humanBytes(totalBytes)})';
}

/// 目录名是否是 group_id 形状（32 位小写十六进制）。
///
/// ## 为什么刻意严格
///
/// 这是删除操作的**唯一准入门槛**。宽松一点（允许大写、允许长度可变）会让
/// 用户自己名为 `a1b2` 的目录进入候选列表——那是个不可逆的数据损失。宁可
/// 漏掉个别形状异常的 group（用户手动删即可），也不能误删用户文件。
///
/// 32 位小写十六进制对齐 Go 侧 `internal/repo/sqlite/store.go` 的 `NewID`
/// （`uuid4().hex`，无连字符）。
bool isGroupId(String name) {
  if (name.length != 32) return false;
  for (final code in name.codeUnits) {
    final isDigit = code >= 0x30 && code <= 0x39; // 0-9
    final isLowerHex = code >= 0x61 && code <= 0x66; // a-f
    if (!isDigit && !isLowerHex) return false;
  }
  return true;
}

/// 清理策略。
sealed class PrunePolicy {
  const PrunePolicy();
}

/// 删除「最新文件也早于 [days] 天」的 group。
///
/// [days] 为 `0` 是**显式的「全部可删」**语义（供「清空全部」入口用），
/// 而非「晚于此刻才保留」——后者会让刚写入的文件因 `mtime == now` 幸存，
/// 使「清空」看着像没清干净。
class PruneOlderThanDays extends PrunePolicy {
  const PruneOlderThanDays({required this.days, required this.nowUnix});

  final int days;
  final int nowUnix;
}

/// 删除不在保留集合里的 group（孤儿清理）。
///
/// 当前无生产调用方：需要「用户当前 group 列表」这个数据源。保留实现（含
/// 单测）以便接入孤儿清理时直接使用。
class PruneNotInKeepList extends PrunePolicy {
  const PruneNotInKeepList(this.keep);

  final Set<String> keep;
}

/// 一个待删除项（含展示信息，供确认对话框使用）。
class PruneCandidate {
  const PruneCandidate({
    required this.groupId,
    required this.fileCount,
    required this.totalBytes,
    required this.reason,
  });

  final String groupId;
  final int fileCount;
  final int totalBytes;

  /// 触发删除的原因（展示给用户，避免「为什么删了这个」）。
  final String reason;

  @override
  String toString() => 'PruneCandidate($groupId, $reason)';
}

/// 清理计划。
class PrunePlan {
  const PrunePlan({this.candidates = const [], this.kept = 0});

  /// 待删除项。
  final List<PruneCandidate> candidates;

  /// 保留项数量（供「将删除 X / 保留 Y」展示）。
  final int kept;

  bool get isEmpty => candidates.isEmpty;

  /// 待删除总字节数。
  int get totalBytes => candidates.fold(0, (sum, c) => sum + c.totalBytes);

  /// 待删除总文件数。
  int get totalFiles => candidates.fold(0, (sum, c) => sum + c.fileCount);

  /// 人类可读摘要。
  String summarize() {
    if (candidates.isEmpty) return '无需清理（保留 $kept 个对话目录）';
    return '将删除 ${candidates.length} 个对话目录'
        '（$totalFiles 个文件，${humanBytes(totalBytes)}），保留 $kept 个';
  }

  @override
  String toString() => 'PrunePlan(${summarize()})';
}

/// 计算清理计划（**纯函数**，不触碰磁盘）。
///
/// 调用方须保证 [groups] 来自扫描层（已通过形状与软链校验）。
PrunePlan buildPrunePlan({
  required List<LocalGroupStats> groups,
  required PrunePolicy policy,
}) {
  final candidates = <PruneCandidate>[];
  var kept = 0;

  for (final g in groups) {
    switch (policy) {
      case PruneOlderThanDays(:final days, :final nowUnix):
        final cutoff = nowUnix - days * 86400;
        // days == 0 是显式的「全部可删」（见 PruneOlderThanDays 说明）。
        final stale = days == 0
            ? true
            // 空目录没有 mtime：视为可清理（同步没产出内容，留着也没用）。
            : (g.newestMtime == null || g.newestMtime! < cutoff);
        if (stale) {
          candidates.add(
            PruneCandidate(
              groupId: g.groupId,
              fileCount: g.fileCount,
              totalBytes: g.totalBytes,
              reason: g.newestMtime == null ? '空目录' : '超过 $days 天未更新',
            ),
          );
        } else {
          kept++;
        }

      case PruneNotInKeepList(:final keep):
        if (keep.contains(g.groupId)) {
          kept++;
        } else {
          candidates.add(
            PruneCandidate(
              groupId: g.groupId,
              fileCount: g.fileCount,
              totalBytes: g.totalBytes,
              reason: '不在保留列表中',
            ),
          );
        }
    }
  }

  // 稳定排序：体积大的先删（用户更关心省空间），同体积按 id 保证可复现。
  candidates.sort((a, b) {
    final bySize = b.totalBytes.compareTo(a.totalBytes);
    return bySize != 0 ? bySize : a.groupId.compareTo(b.groupId);
  });

  return PrunePlan(candidates: candidates, kept: kept);
}

/// 字节数 → 人类可读字符串（如 `1.2 MB`）。
///
/// 二进制单位（1024 进制）而非十进制：与文件管理器、`du` 的显示一致，
/// 避免用户对着两个数字困惑。
String humanBytes(int bytes) {
  const kb = 1024.0;
  final b = bytes.toDouble();
  if (b < kb) return '$bytes B';
  if (b < kb * kb) return '${(b / kb).toStringAsFixed(1)} KB';
  if (b < kb * kb * kb) return '${(b / (kb * kb)).toStringAsFixed(1)} MB';
  return '${(b / (kb * kb * kb)).toStringAsFixed(2)} GB';
}

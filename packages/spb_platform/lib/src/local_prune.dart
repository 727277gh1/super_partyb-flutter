/// 本地同步目录的扫描与清理执行（**真实文件系统**，含安全校验）。
///
/// ## 与 `spb_domain/sync_prune.dart` 的分工
///
/// - **计划**（删什么、为什么删、体积多少）→ domain 的 [buildPrunePlan]，
///   纯函数，可无头单测；
/// - **扫描与执行**（读目录、递归统计、真正删除）→ 本文件，需要 `dart:io`。
///
/// 分开的理由：删除逻辑里真正危险的是「哪些条目**有资格**进入候选」，
/// 那部分必须是可审计、可单测的纯规则；而 IO 部分只做「按计划删」。
///
/// ## 安全约束（这是删除代码，必须保守）
///
/// 1. **只认 group_id 形状的目录名**（[isGroupId]）——同步目录是用户自己的
///    目录，任何不符合该形状的条目一律不碰（同时天然排除 `.git` 等）；
/// 2. **不跟随符号链接**——用 `followLinks: false` 判类型。名为 group_id 的
///    软链可能指向 `~`，跟随删除会造成灾难性后果；
/// 3. **删除前重新校验**——防 TOCTOU（扫描后该路径可能被替换成软链接）；
/// 4. **校验路径仍在 `localRoot` 之内**，且**只删到 group 目录这一层**。
library;

import 'dart:io';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';

// 清理结果类型定义在 domain（纯数据，见 sync_prune.dart 的说明）；
// 这里 re-export，使既有 `import 'package:spb_platform/spb_platform.dart'`
// 的调用方无需改动。
export 'package:spb_domain/spb_domain.dart' show PruneOutcome;

/// 扫描 `localRoot` 下的 group 目录。
///
/// 只返回**通过全部安全校验**的目录（见文件头）。不符合条件的条目**静默
/// 跳过**——用户自己的文件不该让清理功能报错。
///
/// 目录不存在时返回空列表（没有可清理的，不是错误）。
Future<List<LocalGroupStats>> scanLocalGroups(String localRoot) async {
  final dir = Directory(localRoot);
  if (!await dir.exists()) return const [];

  final out = <LocalGroupStats>[];
  final resolvedRoot = await _resolvedRootOrNull(localRoot);

  await for (final entity in dir.list(followLinks: false)) {
    final name = _basename(entity.path);
    if (!isGroupId(name)) continue; // 用户自己的文件/目录：不碰

    // WHY followLinks: false —— 跟随软链会把「删目录」变成「删链接指向的目标」。
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type != FileSystemEntityType.directory) continue;

    // 兜底：确认路径确实在 localRoot 之下（防拼接意外）。
    if (resolvedRoot != null) {
      final resolved = await _resolveOrNull(entity.path);
      if (resolved == null || !_isWithin(resolved, resolvedRoot)) continue;
    }

    out.add(await _walkStats(name, entity.path));
  }

  // 排序保证输出可复现（目录列举顺序依赖文件系统）。
  out.sort((a, b) => a.groupId.compareTo(b.groupId));
  return out;
}

/// 汇总本地统计（供设置页「本地统计」展示）。
///
/// 与 [scanLocalGroups] 用同一套准入规则，避免「统计里显示 10 个目录、
/// 清理时只认 8 个」这种不一致。
Future<LocalSyncStats> scanLocalStats(String localRoot) async {
  final groups = await scanLocalGroups(localRoot);
  if (groups.isEmpty) return LocalSyncStats.empty;
  return LocalSyncStats(
    groupCount: groups.length,
    fileCount: groups.fold(0, (s, g) => s + g.fileCount),
    totalBytes: groups.fold(0, (s, g) => s + g.totalBytes),
  );
}

/// 执行清理计划。
///
/// 每个候选**在删除前重新走一遍校验**（防 TOCTOU）：扫描与删除之间可能隔了
/// 一次用户确认，期间该路径可能被替换成软链接或换成一个文件。故不能复用扫描
/// 时的结论。
///
/// 单个失败**不阻断**其余：一个权限问题不该让整次清理白跑。
Future<PruneOutcome> executePrunePlan({
  required String localRoot,
  required PrunePlan plan,
}) async {
  var deleted = 0;
  final failed = <String, String>{};

  final resolvedRoot = await _resolvedRootOrNull(localRoot);
  if (resolvedRoot == null) {
    // 目录不存在：没有可删的（幂等），不算失败。
    return const PruneOutcome(deleted: 0, failed: {});
  }

  for (final candidate in plan.candidates) {
    final gid = candidate.groupId;
    try {
      // 形状必须在删除前**再判一次**：计划可能来自外部（如持久化后重放）。
      if (!isGroupId(gid)) {
        failed[gid] = '目录名不是 group_id 形状，已跳过';
        continue;
      }

      final path = '$resolvedRoot/$gid';

      // 重新判类型（防 TOCTOU：扫描时是目录，现在可能是软链）。
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue; // 已被删掉：幂等成功
      if (type != FileSystemEntityType.directory) {
        failed[gid] = '不是真实目录（可能是符号链接），已跳过';
        continue;
      }

      final resolved = await _resolveOrNull(path);
      if (resolved == null || !_isWithin(resolved, resolvedRoot)) {
        failed[gid] = '解析后落在同步目录之外，已跳过';
        continue;
      }

      // 只删 group 目录这一层（不是递归删任意深度路径）。
      await Directory(path).delete(recursive: true);
      deleted++;
    } catch (e) {
      failed[gid] = e.toString();
    }
  }

  return PruneOutcome(deleted: deleted, failed: failed);
}

/// 递归统计目录的文件数、总字节数与最新 mtime。
///
/// **不跟随软链**：既避免统计到目录外，也避免软链成环导致无限递归。
Future<LocalGroupStats> _walkStats(String groupId, String path) async {
  var fileCount = 0;
  var totalBytes = 0;
  int? newest;

  Future<void> walk(Directory dir) async {
    await for (final entity in dir.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await walk(Directory(entity.path));
      } else if (type == FileSystemEntityType.file) {
        fileCount++;
        try {
          final stat = await File(entity.path).stat();
          totalBytes += stat.size;
          final ms = stat.modified.millisecondsSinceEpoch;
          if (newest == null || ms > newest!) newest = ms;
        } on FileSystemException catch (e) {
          // 统计失败（权限/竞态）不该让整个扫描失败：文件数已计，体积略过。
          SpbLog.debug('统计文件失败，已跳过其体积', {
            'path': entity.path,
            'error': e.toString(),
          });
        }
      }
      // 软链等其他类型：不计入（见函数说明）。
    }
  }

  try {
    await walk(Directory(path));
  } on FileSystemException catch (e) {
    SpbLog.warn('扫描 group 目录失败', {'path': path, 'error': e.toString()});
  }

  return LocalGroupStats(
    groupId: groupId,
    fileCount: fileCount,
    totalBytes: totalBytes,
    // 转成 Unix 秒（对齐 domain 侧策略的 nowUnix）。
    newestMtime: newest == null ? null : newest! ~/ 1000,
  );
}

/// 解析 `localRoot` 的真实路径；不存在或无法解析时返回 null。
Future<String?> _resolvedRootOrNull(String localRoot) async {
  if (localRoot.trim().isEmpty) return null;
  final type = await FileSystemEntity.type(localRoot);
  if (type != FileSystemEntityType.directory) return null;
  return _resolveOrNull(localRoot);
}

Future<String?> _resolveOrNull(String path) async {
  try {
    return _normalize(await Directory(path).resolveSymbolicLinks());
  } on FileSystemException {
    return null;
  }
}

String _basename(String path) {
  final normalized = _normalize(path);
  final idx = normalized.lastIndexOf('/');
  return idx < 0 ? normalized : normalized.substring(idx + 1);
}

/// 统一分隔符（Windows 的 `resolveSymbolicLinks` 返回 `\`）。
String _normalize(String path) => path.replaceAll(r'\', '/');

/// [path] 是否位于 [root] 之内（含等于 root 本身）。
bool _isWithin(String path, String root) {
  final p = _normalize(path);
  final r = _normalize(root);
  return p == r || p.startsWith('$r/');
}

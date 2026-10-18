/// 本地落盘实现：**原子写入** + **路径穿越防御**。
///
/// 实现 `spb_domain` 的 [FileSink]（契约在 domain，因为 domain 不能依赖
/// `dart:io`——那会让「同步纯逻辑」变成「只能在有文件系统的环境里测试」）。
///
/// ## 两条安全/正确性要求
///
/// ### 1. 路径穿越防御
///
/// 同步器会**按远端返回的路径名写本地文件**，而远端路径是服务端可控的输入。
/// 一旦其中出现 `..` 或绝对路径，就能让写入逃出用户所选目录——覆盖
/// `~/.ssh/authorized_keys` 之类只是其中一例。
///
/// 防御分两层：
/// - **第一层（计划期）**：`spb_domain` 的 `groupRelativePath` /
///   `workspaceRelativePath` 在生成计划时就拒掉含 `..`、绝对路径、`\`、NUL
///   的路径，非法路径根本不进入动作列表；
/// - **第二层（落盘期，本文件）**：即使 `relPath` 已经过第一层，写入前仍重新
///   校验，并额外解析**符号链接**——`local_root` 内的一个指向外部的软链同样
///   能造成逃逸，而第一层看不见它（它只检查字符串形态）。
///
/// 纵深防御的理由：第一层保证「正常路径不会逃逸」，第二层保证「万一第一层
/// 被绕过（未来有人改了 domain 的校验、或调用方直接构造 relPath）也不会
/// 写出用户目录」。
///
/// ### 2. 原子写入
///
/// 先写 `*.part` 再 `rename`。同步中途崩溃/断网若留下半截文件，它会**看起来
/// 像一份完整交付物**，用户不会察觉。同一文件系统内 `rename` 是原子的。
library;

import 'dart:io';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';

/// 把相对路径安全地解析为 `localRoot` 内的绝对路径。
///
/// 返回的路径保证位于 `localRoot`（已解析符号链接）之内；任何逃逸尝试都抛
/// [PlatformError]。
///
/// ## 校验顺序与理由
///
/// 1. **字符串形态**（空、绝对路径、`..`、`.`、空段、`\`、NUL）——
///    纯字符串检查，不碰磁盘，因此对不存在的路径也有效；
/// 2. **根目录必须存在**——`resolveSymbolicLinks` 对不存在的路径会抛异常，
///    而「用户选的目录被删了」应当是明确错误，不是静默写失败；
/// 3. **符号链接解析**——取**最深的已存在祖先**（含 target 自身）解析。
///    只查祖先不够：target 自身可能就是根目录内一个指向外部的软链，写入会
///    跟着它逃逸。反过来只查 target 也不够：多级中间目录里任一段是软链都会
///    逃逸。故取「最深已存在者」一次性覆盖两种情况。
Future<String> resolveWithinRoot(String localRoot, String relPath) async {
  final segments = _safeSegments(relPath);

  final root = await _resolvedRoot(localRoot);
  final target = '$root/${segments.join('/')}';

  // 找最深的已存在路径（从 target 往上走），解析它，确认仍在 root 之内。
  var probe = target;
  while (true) {
    final type = await FileSystemEntity.type(probe, followLinks: false);
    if (type != FileSystemEntityType.notFound) break;
    final parent = _parentOf(probe);
    if (parent == null || parent == probe) break;
    probe = parent;
  }

  final resolvedProbe = await _resolveLinks(probe);
  if (!_isWithin(resolvedProbe, root)) {
    throw PlatformError(
      '路径逃逸被拒绝：$relPath 解析后落在同步目录之外',
      cause: 'resolved=$resolvedProbe root=$root',
    );
  }
  return target;
}

/// 拆出并校验路径段；非法时抛 [PlatformError]。
///
/// 与 `spb_domain` 的 `isValidPathSegment` 规则一致，但**独立实现**：
/// 落盘层不能假设调用方一定来自第一层校验。
List<String> _safeSegments(String relPath) {
  if (relPath.isEmpty) {
    throw const PlatformError('路径为空');
  }
  // 绝对路径：`/etc/passwd`、Windows 的 `C:\...`、UNC 的 `\\host\share`。
  // 判 `\` 要在分段之前，因为它在 Windows 上是分隔符，分段看不出来。
  if (relPath.startsWith('/') || relPath.startsWith(r'\')) {
    throw PlatformError('拒绝绝对路径：$relPath');
  }
  if (relPath.length >= 2 && relPath[1] == ':') {
    throw PlatformError('拒绝盘符路径：$relPath');
  }

  final segments = relPath.split('/');
  for (final segment in segments) {
    if (segment.isEmpty) {
      throw PlatformError('路径含空段：$relPath');
    }
    if (segment == '.' || segment == '..') {
      throw PlatformError('拒绝路径穿越（$segment）：$relPath');
    }
    if (segment.contains(r'\')) {
      throw PlatformError(r'路径段含反斜杠（Windows 分隔符）：' + relPath);
    }
    if (segment.contains('\u0000')) {
      throw PlatformError('路径段含 NUL：$relPath');
    }
  }
  return segments;
}

/// 解析 `localRoot` 的绝对真实路径；不存在或不是目录时报错。
Future<String> _resolvedRoot(String localRoot) async {
  if (localRoot.isEmpty) {
    throw const PlatformError('同步目录未设置');
  }
  final type = await FileSystemEntity.type(localRoot);
  if (type == FileSystemEntityType.notFound) {
    throw PlatformError('同步目录不存在：$localRoot');
  }
  if (type != FileSystemEntityType.directory) {
    throw PlatformError('同步路径不是目录：$localRoot');
  }
  final resolved = await _resolveLinks(localRoot);
  return _normalize(resolved);
}

Future<String> _resolveLinks(String path) async {
  try {
    return await Directory(path).resolveSymbolicLinks();
  } on FileSystemException catch (e) {
    // 路径可能是普通文件而非目录；换 File 再试。
    try {
      return await File(path).resolveSymbolicLinks();
    } on FileSystemException {
      throw PlatformError('无法解析路径（可能是断链的符号链接）：$path', cause: e);
    }
  }
}

String? _parentOf(String path) {
  final normalized = _normalize(path);
  final idx = normalized.lastIndexOf('/');
  if (idx <= 0) return null;
  return normalized.substring(0, idx);
}

/// 统一分隔符：Windows 的 `resolveSymbolicLinks` 返回 `\` 分隔，
/// 而本文件其余部分按 `/` 处理。归一化后前缀比较才不会漏判。
String _normalize(String path) => path.replaceAll(r'\', '/');

/// [path] 是否位于 [root] 之内（含等于 root 本身）。
bool _isWithin(String path, String root) {
  final p = _normalize(path);
  final r = _normalize(root);
  return p == r || p.startsWith('$r/');
}

/// 基于 `dart:io` 的 [FileSink] 实现。
///
/// 每个实例绑定一个 `localRoot`（用户在设置页选择的同步目录）。
///
/// 同时实现 [LocalFileReader]：回传链路需要把本地内容读出来（脏检测比对 hash、
/// 上传前取字节），而它必须与写入共用同一套路径防御，故放在同一个类里而不是
/// 另起一个只差防御逻辑的类。
class LocalFileSink implements FileSink, LocalFileReader {
  const LocalFileSink(this.localRoot);

  final String localRoot;

  /// 原子写入：先写 `*.part` 再 `rename`。
  ///
  /// 临时文件名带**进程号**：两个同步任务并发写同一目录时不会互相覆盖对方的
  /// 临时文件（rename 会覆盖目标，但临时文件被对方先 rename 走会导致
  /// 「文件不存在」的诡异失败）。
  @override
  Future<void> write(String relPath, List<int> bytes) async {
    final target = await resolveWithinRoot(localRoot, relPath);
    final tmp = '$target.part.$pid';
    try {
      final parent = Directory(_parentOf(target)!);
      await parent.create(recursive: true);
      final file = File(tmp);
      // flush: true —— 保证内容在 rename 前真正落盘（否则断电可能 rename 了
      // 一个内容还在页缓存里的文件，表现为「文件存在但内容不全」）。
      await file.writeAsBytes(bytes, flush: true);
      await file.rename(target);
    } on FileSystemException catch (e) {
      throw StorageError('写入失败：$relPath（${e.message}）', cause: e);
    } on PlatformError {
      // 路径逃逸等：原样上抛，不包装成 StorageError（语义不同，上层要能区分）。
      rethrow;
    }
  }

  /// 删除本地文件；**文件本就不存在视为成功**。
  ///
  /// 用户可能已手动删掉该文件，那不该被当成同步失败——否则这个条目会永远
  /// 留在失败列表里，每轮重试。
  @override
  Future<void> delete(String relPath) async {
    final target = await resolveWithinRoot(localRoot, relPath);
    try {
      await File(target).delete();
    } on FileSystemException catch (e) {
      // ENOENT(2)：文件不存在 → 目标已达成。其余（权限、占用）是真失败。
      if (e.osError?.errorCode == 2) return;
      throw StorageError('删除失败：$relPath（${e.message}）', cause: e);
    }
  }

  /// 磁盘上是否真实存在该文件。
  ///
  /// ## 为什么不能拿状态表代替它
  ///
  /// 同步引擎用它决定要不要发 `If-None-Match`（见 `spb_domain` 的
  /// [FileSink.exists]）。若用「状态里有记录」代替，「用户手动删了文件」就会
  /// 让引擎带着 etag 去问服务端 → 304 → 跳过写入 → **文件永远回不来**。
  ///
  /// 这里先 `resolveWithinRoot` 再判存在：路径穿越的输入应当在这里就被拒掉，
  /// 而不是先落到磁盘上再判（`resolveWithinRoot` 对不存在路径也有效，故顺序
  /// 不影响结果，只影响「非法路径会不会被当成『不存在』而静默放行」）。
  @override
  Future<bool> exists(String relPath) async {
    final target = await resolveWithinRoot(localRoot, relPath);
    return File(target).exists();
  }

  /// 读取本地文件内容（回传链路：脏检测比对 hash、上传前取字节）。
  ///
  /// ## 为什么必须与 [write] 用同一套路径防御
  ///
  /// 回传的 `relPath` 来自状态表（同步时写入的相对路径），看起来是可信的；
  /// 但同步目录是**用户自己的目录**，里面可能有指向外部的软链。若读取不走
  /// `resolveWithinRoot`，一个名为 `link/x.md` 的合法路径就能把同步目录之外
  /// 的文件内容读出来并上传到 UFS——这是**数据外泄**，比写入逃逸更隐蔽。
  ///
  /// ## 文件不存在时必须抛错（不得返回空列表）
  ///
  /// 返回空列表会被上层当成「一个 0 字节的文件」，算出与记录不同的 hash，
  /// 于是被误判为「用户改动过」→ 触发一次覆盖上传，把远端文件写成空文件。
  /// 抛错让上层把该条目记为失败并跳过，是安全的一侧。
  @override
  Future<List<int>> readBytes(String relPath) async {
    final target = await resolveWithinRoot(localRoot, relPath);
    try {
      return await File(target).readAsBytes();
    } on FileSystemException catch (e) {
      // ENOENT(2)：文件不在（用户手动删了 / 被清理）。明确报错而不是返回空，
      // 否则上层会把「读不到」当成「内容变了」而去覆盖远端。
      if (e.osError?.errorCode == 2) {
        throw PlatformError('本地文件不存在：$relPath', cause: e);
      }
      throw StorageError('读取失败：$relPath（${e.message}）', cause: e);
    } on PlatformError {
      // 路径逃逸等：原样上抛（与 write 一致，语义不同，上层要能区分）。
      rethrow;
    }
  }
}

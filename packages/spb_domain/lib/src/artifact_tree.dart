/// Group 交付物清单 → 树（**纯函数**，不碰网络与磁盘）。
///
/// ## 它解决什么
///
/// `GET /ufs/api/files?path_prefix=/workspace/groups/{gid}` 返回的是**扁平**条目
/// 列表（文件与目录混在一起）。展示给用户的是一棵树：`reports/` 目录下挂着
/// `spec.md`、`v2.md`…… 本函数把扁平列表归一成可渲染的嵌套结构。
///
/// 对齐 webapp `WorkbenchGroupDocsPanel.tsx::buildArtifactTree` 的语义，但有两处
/// 刻意差异（见各处说明）。
///
/// ## 为什么放进 domain（纯函数）
///
/// 建树规则（隐式目录如何创建、计数如何向上聚合、排序如何稳定）是最容易写错
/// 且最难在生产排查的部分——与 `buildPrunePlan` 同理。把它做成纯函数后，可用
/// 内存桩逐条断言，无需 UFS、无需 Flutter 引擎（`spb_domain` 禁止依赖 Flutter）。
///
/// ## 路径映射的唯一权威：[groupRelativePath]
///
/// 剥 `/workspace/groups/{gid}/` 前缀用的是 `sync_path.dart` 的
/// [groupRelativePath]——它**同时**带路径穿越防御（拒绝 `..` / `.` / `\` / NUL），
/// 与交付物同步共用同一套规则，保证「侧边栏看到的路径」与「同步落到磁盘的路径」
/// 一致。webapp 的 `getGroupWorkspaceRelativePath` 还会优先取
/// `metadata.relative_path`；本实现**刻意不取**，理由见 [buildArtifactTree]。
library;

import 'package:spb_models/spb_models.dart';

import 'sync_path.dart';

/// 时间戳比较时的「零点」（`updated_at` 缺失时排到最后）。
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// 可渲染的树节点。
sealed class ArtifactNode {
  const ArtifactNode();

  /// 组内相对路径（如 `reports/v2.md` 或 `reports`）。
  ///
  /// 已剥掉 `/workspace/groups/{gid}/` 前缀，可直接用作 Flutter 的 `ValueKey`
  /// （同一 group 内唯一标识一个节点）与折叠状态键。
  String get relativePath;

  /// 用户可见名（目录用末段，文件用 nice_name 优先）。
  String get name;

  /// 该节点（含子树）最新更新时间；缺失为 null。
  DateTime? get latestUpdatedAt;

  /// 是否目录。
  bool get isDirectory;
}

/// 目录节点。
///
/// [children] 已排序（目录在前、文件在后；详见 [buildArtifactTree] 的排序规则）。
/// [fileCount] / [totalBytes] / [latestUpdatedAt] 均为**递归聚合**：一个目录的
/// 计数包含其全部后代文件。
final class ArtifactDirectoryNode extends ArtifactNode {
  const ArtifactDirectoryNode({
    required this.name,
    required this.relativePath,
    required this.children,
    required this.fileCount,
    required this.totalBytes,
    required this.latestUpdatedAt,
    this.entry,
  });

  @override
  final String name;

  @override
  final String relativePath;

  /// 子节点（已排序）。
  ///
  /// 不可变视图：[buildArtifactTree] 返回后不应再修改。
  final List<ArtifactNode> children;

  /// 子树内**文件**总数（不含目录条目本身）。
  final int fileCount;

  /// 子树内文件总字节数。
  final int totalBytes;

  @override
  final DateTime? latestUpdatedAt;

  /// 对应的 UFS 目录条目（`is_directory == true` 的那条记录），可能为 null：
  ///
  /// - 该目录是「隐式」的——只因为某个文件的路径里出现了这段，UFS 并没有单独的
  ///   目录条目。侧边栏展示不需要它；将来若要「把目录部署为 Spec 站点」（需要
  ///   目录的 `file_id`）才会用上。
  final UfsFileEntry? entry;

  @override
  bool get isDirectory => true;

  @override
  String toString() => 'ArtifactDirectoryNode($relativePath, $fileCount 个文件)';
}

/// 文件节点。
final class ArtifactFileNode extends ArtifactNode {
  const ArtifactFileNode({
    required this.file,
    required this.name,
    required this.relativePath,
    required this.latestUpdatedAt,
  });

  /// 原始 UFS 条目。下载 / 类型判定 / 大小展示都取它。
  final UfsFileEntry file;

  @override
  final String name;

  @override
  final String relativePath;

  @override
  final DateTime? latestUpdatedAt;

  @override
  bool get isDirectory => false;

  @override
  String toString() => 'ArtifactFileNode($relativePath)';
}

/// 把扁平的 UFS 条目列表归一成**根节点列表**。
///
/// 返回的是**根的列表**（而非单个根节点）：一个 group 的 workspace 下可直接
/// 出现顶层文件，也可能有多个顶层目录，顶层是平铺的而非统一挂在一个虚拟根下。
/// 这与 webapp 的返回类型一致，便于侧边栏直接 `Column(roots)`。
///
/// ## 入参
///
/// [entries] 由调用方按 `path_prefix=/workspace/groups/{gid}` 从 UFS 拉取；
/// 文件与目录条目可混在一起，本函数自行分拣。[groupId] 必填，空串直接返回空
/// （避免前缀退化成 `/workspace/groups//` 把不属于任何 group 的条目收进来）。
///
/// [includeDeleted] 默认 `false`：软删的文件不进树（侧边栏展示的是「现在有什么」，
/// 与内联卡「展示生命周期含已删除」的语义不同）。同步链路另有自己的删除感知
/// 逻辑，不走这里。
///
/// ## 路径过滤与穿越防御
///
/// 每个条目先用 [groupRelativePath] 剥前缀；它同时拒绝 `..` / `.` / `\` / NUL 与
/// 不属于该 group 的路径，返回 null 一律跳过——**不会**进入树。这条安全边界与
/// 交付物同步共用，故侧边栏看到的目录结构不会成为路径穿越的入口。
///
/// ## 隐式目录
///
/// UFS 只在显式建过目录时才有 `is_directory == true` 的条目；更多情况下目录是
/// 由文件路径的中间段**隐式**定义的（`reports/v2.md` 里没有 `reports` 条目）。
/// 本函数为这类中间段自动创建 [ArtifactDirectoryNode]（`entry` 为 null）。
///
/// ## 聚合
///
/// 每个文件的计数（[ArtifactDirectoryNode.fileCount] / [totalBytes]）与时间
/// （[latestUpdatedAt]）向上累加到它**全部祖先**目录（而非仅直接父目录）——
/// 这样根级目录就能直接显示「这个 group 一共 N 个文件、最新几点更新」，无需
/// UI 再递归一遍。
///
/// ## 刻意与 webapp 的两处差异
///
/// 1. **不取 `metadata.relative_path`**：webapp 优先用它定位文件；本实现只看
///    UFS materialized path。理由是**与同步链路对齐**：同步按 path 落盘，侧边栏
///    按 path 建树，两者用同一来源（[groupRelativePath]），不会因 metadata 与
///    path 偶发不一致而出现「侧边栏看到的路径 ≠ 磁盘上的路径」。代价是若某文件
///    的 metadata.relative_path 与 path 不同步，侧边栏展示的是 path 视角——这是
///    可接受的取舍，且这种不一致在生产中本就是数据质量问题。
///
/// 2. **同时间戳的排序用 code-unit 比较**而非 webapp 的 `localeCompare("zh-CN")`。
///    Dart 标准库无内置 locale 排序，引入 `intl` 为一棵树不值当；中文文件名落到
///    code unit 顺序（按 Unicode 码点）仍**稳定且可复现**，只是不符合拼音序。
///
/// ## 排序规则（递归应用到每个 [ArtifactDirectoryNode.children]）
///
/// 1. 目录在前、文件在后；
/// 2. [latestUpdatedAt] 新的在前（用户最关心最近更新的）；
/// 3. 同时间戳按 [name] 大小写不敏感比较（稳定兜底）。
List<ArtifactNode> buildArtifactTree(
  Iterable<UfsFileEntry> entries, {
  required String groupId,
  bool includeDeleted = false,
}) {
  if (groupId.isEmpty) return const [];

  // 真实目录条目：rel → UFS 条目（用于把隐式目录关联回真实 file_id）。
  final directoryEntryByPath = <String, UfsFileEntry>{};
  for (final e in entries) {
    if (!e.isDirectory) continue;
    if (!includeDeleted && e.isDeleted) continue;
    final rel = groupRelativePath(e.path, groupId);
    if (rel == null) continue;
    directoryEntryByPath[rel] = e;
  }

  // ── 1. 先分拣：文件条目 + 需要存在的目录路径集合 ────────────────────────
  //
  // 两趟而非一趟：先把「所有需要存在的目录路径」收齐（含文件路径里的**隐式**
  // 中间段），再按**深度升序**创建累加器。这样创建每个目录时其父目录必然已
  // 存在，不需要在 `putIfAbsent` 回调里递归创建（Dart 明确禁止在 `ifAbsent`
  // 执行期间修改同一个 map——重入会抛 `ConcurrentModificationError`）。
  final dirPaths = <String>{};
  final fileEntries = <(String, UfsFileEntry)>[];

  for (final e in entries) {
    if (!includeDeleted && e.isDeleted) continue;
    final rel = groupRelativePath(e.path, groupId);
    if (rel == null) continue;
    if (e.isDirectory) {
      dirPaths.add(rel);
      continue;
    }
    fileEntries.add((rel, e));
    // 文件路径的全部中间段都是目录（含隐式目录）。
    var parentRel = _parentPath(rel);
    while (parentRel != null) {
      dirPaths.add(parentRel);
      parentRel = _parentPath(parentRel);
    }
  }

  // ── 2. 按深度升序创建目录累加器（父先于子）────────────────────────────
  final dirs = <String, _DirAcc>{};
  final orderedDirPaths = dirPaths.toList()
    ..sort((a, b) {
      final byDepth = _depth(a).compareTo(_depth(b));
      return byDepth != 0 ? byDepth : a.compareTo(b);
    });
  for (final rel in orderedDirPaths) {
    dirs[rel] = _DirAcc(
      relativePath: rel,
      name: _leafName(rel),
      entry: directoryEntryByPath[rel],
    );
  }

  // ── 3. 链接目录 → 父目录（根目录不挂）───────────────────────────────
  final roots = <Object>[];
  for (final rel in orderedDirPaths) {
    final acc = dirs[rel]!;
    final parentRel = _parentPath(rel);
    final parent = parentRel == null ? null : dirs[parentRel];
    if (parent != null) {
      parent.children.add(acc);
    } else {
      roots.add(acc);
    }
  }

  // ── 4. 挂文件 + 计数/时间向上聚合到全部祖先 ───────────────────────────
  for (final (rel, e) in fileEntries) {
    final ts = e.updatedAt;
    final node = ArtifactFileNode(
      file: e,
      name: _displayName(e, rel),
      relativePath: rel,
      latestUpdatedAt: ts,
    );
    final parentRel = _parentPath(rel);
    final parent = parentRel == null ? null : dirs[parentRel];
    if (parent != null) {
      parent.children.add(node);
    } else {
      roots.add(node);
    }

    // 聚合到父目录及其全部祖先（非仅直接父目录），使根级目录直接可展示
    // 「共 N 个文件 / 最新更新时间」，无需 UI 再递归。
    if (parentRel != null) {
      for (final ancestor in _ancestorPaths(parentRel)) {
        final acc = dirs[ancestor];
        if (acc == null) continue;
        acc.fileCount += 1;
        acc.totalBytes += e.size;
        if (ts != null && (acc.latest == null || ts.isAfter(acc.latest!))) {
          acc.latest = ts;
        }
      }
    }
  }

  // ── 5. 排序（递归）───────────────────────────────────────────────
  for (final acc in dirs.values) {
    acc.children.sort(_compareNodes);
  }
  roots.sort(_compareNodes);

  return roots.map(_freeze).toList(growable: false);
}

/// 路径深度（段数）。`a` → 1，`a/b` → 2。
int _depth(String rel) => rel.split('/').length;

/// 冻结期间用的可变累加器。
class _DirAcc {
  _DirAcc({
    required this.relativePath,
    required this.name,
    required this.entry,
  });

  final String relativePath;
  final String name;
  final UfsFileEntry? entry;
  final List<Object> children = []; // _DirAcc | ArtifactFileNode（冻结前混合）
  int fileCount = 0;
  int totalBytes = 0;
  DateTime? latest;
}

/// 把累加器树冻结成不可变节点。
ArtifactNode _freeze(Object node) {
  if (node is ArtifactFileNode) return node;
  final d = node as _DirAcc;
  return ArtifactDirectoryNode(
    name: d.name,
    relativePath: d.relativePath,
    children: d.children.map(_freeze).toList(growable: false),
    fileCount: d.fileCount,
    totalBytes: d.totalBytes,
    latestUpdatedAt: d.latest,
    entry: d.entry,
  );
}

/// 节点排序：目录在前 → 时间新在前 → 名字（大小写不敏感）兜底。
int _compareNodes(Object a, Object b) {
  final aIsDir = a is _DirAcc;
  final bIsDir = b is _DirAcc;
  if (aIsDir != bIsDir) return aIsDir ? -1 : 1;

  final ta = _nodeTs(a);
  final tb = _nodeTs(b);
  if (ta != tb) return tb.compareTo(ta);

  return _nodeName(a).toLowerCase().compareTo(_nodeName(b).toLowerCase());
}

DateTime _nodeTs(Object n) {
  if (n is _DirAcc) return n.latest ?? _epoch;
  return (n as ArtifactFileNode).latestUpdatedAt ?? _epoch;
}

String _nodeName(Object n) {
  if (n is _DirAcc) return n.name;
  return (n as ArtifactFileNode).name;
}

/// 组内相对路径 → 父目录相对路径。顶层（无 `/`）返回 null。
String? _parentPath(String rel) {
  final i = rel.lastIndexOf('/');
  // i < 0：无分隔符（顶层）；i == 0：前导 `/`，但 groupRelativePath 保证无前导
  // 斜杠，故不会出现。
  if (i <= 0) return null;
  return rel.substring(0, i);
}

/// 相对路径 → 自顶向下的祖先链（**含自身**）。
///
/// 例：`reports/2026` → `['reports', 'reports/2026']`。
///
/// 调用方传的是文件的「父目录」相对路径，聚合时要 bump 父目录**及其全部祖先**
/// （含父目录自身），故这里包含入参本身。
List<String> _ancestorPaths(String rel) {
  final segments = rel.split('/');
  final out = <String>[];
  for (var i = 1; i <= segments.length; i++) {
    out.add(segments.sublist(0, i).join('/'));
  }
  return out;
}

String _leafName(String rel) {
  final i = rel.lastIndexOf('/');
  return i < 0 ? rel : rel.substring(i + 1);
}

/// 文件展示名：`metadata_json.nice_name` 优先，否则用 [UfsFileEntry.name]，
/// 兜底用**相对路径**末段。
///
/// ## 为什么兜底必须用 [rel] 而不是 [UfsFileEntry.path]
///
/// UFS 的物化路径对文件也带尾斜杠（`.../a.md/`），对它取末段得到的是空串。
/// [rel] 已由 [groupRelativePath] 剥过前缀与尾斜杠，末段才是真正的文件名。
String _displayName(UfsFileEntry e, String rel) {
  final nice = e.metadata?['nice_name']?.toString().trim();
  if (nice != null && nice.isNotEmpty) return nice;
  if (e.name.isNotEmpty) return e.name;
  return _leafName(rel);
}

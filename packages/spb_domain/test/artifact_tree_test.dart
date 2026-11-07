import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 交付物建树（`buildArtifactTree`）测试。
///
/// ## 这个测试防的是什么
///
/// 侧边栏展示的是「这个 group 现在有哪些文件」的**权威快照**。建树规则一旦写错，
/// 用户看到的就是一份错误的清单——而它看起来完全正常（不报错、不崩溃），只是
/// 少了文件或路径不对。故逐条锁定：
///
/// - **路径映射**必须与交付物同步共用同一套规则（`groupRelativePath`），否则
///   「侧边栏看到的路径」与「同步落到磁盘的路径」会分叉；
/// - **穿越防御**：`..` / `.` / `\` / NUL / 非本 group 的路径一律不进树
///   ——侧边栏是展示层，但它读的是服务端可控的输入，不能成为穿越入口；
/// - **隐式目录**：UFS 只在显式建过目录时才有目录条目，多数目录由文件路径
///   中间段定义。漏了这条，`reports/spec.md` 会变成一个孤零零的根级文件；
/// - **聚合**：计数/体积/最新时间要向上累加到**全部祖先**（不是只有直接父级），
///   否则根级目录显示「0 个文件」；
/// - **排序稳定**：目录在前、时间新在前、同名可比 —— 顺序漂移会让 UI 抖动。

const _gid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherGid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// 构造 UFS 条目。
///
/// `path` 默认带**尾斜杠**——这是 UFS 实测行为（`buildMaterializedPath`
/// 无条件拼 `name + '/'`），不带的话测试会掩盖真实场景。
UfsFileEntry _entry(
  String rel, {
  String? id,
  int size = 10,
  String? mime = 'text/markdown',
  String updatedAt = '2026-01-01T00:00:00Z',
  bool deleted = false,
  bool directory = false,
  Map<String, dynamic>? metadata,
  String? path,
  String? name,
}) => UfsFileEntry.fromJson({
  'id': id ?? 'id-$rel',
  'path': path ?? '/workspace/groups/$_gid/$rel/',
  'name': name ?? rel.split('/').last,
  'size': size,
  'mime_type': mime,
  'is_directory': directory,
  if (deleted) 'deleted_at': '2026-02-01T00:00:00Z',
  if (metadata != null) 'metadata_json': metadata,
  'updated_at': updatedAt,
});

/// 扁平化树里的全部相对路径（便于断言结构而不写一长串嵌套期望）。
List<String> _paths(List<ArtifactNode> nodes) {
  final out = <String>[];
  void walk(List<ArtifactNode> ns) {
    for (final n in ns) {
      out.add(n.relativePath);
      if (n is ArtifactDirectoryNode) walk(n.children);
    }
  }

  walk(nodes);
  return out;
}

/// 按相对路径取节点（找不到返回 null）。
ArtifactNode? _find(List<ArtifactNode> nodes, String rel) {
  for (final n in nodes) {
    if (n.relativePath == rel) return n;
    if (n is ArtifactDirectoryNode) {
      final hit = _find(n.children, rel);
      if (hit != null) return hit;
    }
  }
  return null;
}

ArtifactDirectoryNode _dir(List<ArtifactNode> nodes, String rel) {
  final n = _find(nodes, rel);
  expect(n, isA<ArtifactDirectoryNode>(), reason: '$rel 应为目录');
  return n! as ArtifactDirectoryNode;
}

void main() {
  // =========================================================================
  group('基本结构', () {
    test('空列表 → 空树', () {
      expect(buildArtifactTree(const [], groupId: _gid), isEmpty);
    });

    test('空 groupId → 空树（不把别的 group 的条目收进来）', () {
      // 空 groupId 会让前缀退化成 `/workspace/groups//`，语义不成立。
      final tree = buildArtifactTree([_entry('a.md')], groupId: '');
      expect(tree, isEmpty);
    });

    test('顶层文件直接挂根，不造虚拟根目录', () {
      final tree = buildArtifactTree([_entry('README.md')], groupId: _gid);
      expect(tree, hasLength(1));
      expect(tree.single, isA<ArtifactFileNode>());
      expect(tree.single.relativePath, 'README.md');
    });

    test('嵌套文件产生隐式中间目录', () {
      final tree = buildArtifactTree([
        _entry('reports/2026/spec.md'),
      ], groupId: _gid);

      expect(_paths(tree), ['reports', 'reports/2026', 'reports/2026/spec.md']);
      expect(_dir(tree, 'reports').entry, isNull, reason: '隐式目录无 UFS 条目');
      expect(_dir(tree, 'reports/2026').entry, isNull);
    });

    test('显式目录条目关联到目录节点的 entry（供将来部署站点用）', () {
      final dirEntry = _entry('reports', id: 'dir-1', directory: true);
      final tree = buildArtifactTree([
        dirEntry,
        _entry('reports/spec.md'),
      ], groupId: _gid);

      final reports = _dir(tree, 'reports');
      expect(reports.entry, isNotNull);
      expect(reports.entry!.id, 'dir-1');
    });

    test('文件与目录条目混在一起也能正确分拣', () {
      final tree = buildArtifactTree([
        _entry('assets', directory: true),
        _entry('assets/logo.png'),
        _entry('README.md'),
      ], groupId: _gid);

      expect(
        _paths(tree),
        containsAll(['assets', 'assets/logo.png', 'README.md']),
      );
    });

    test('UFS 尾斜杠被剥掉（文件路径也带尾斜杠）', () {
      // 实测 UFS 对文件也拼尾斜杠；不剥的话尾段为空，全部文件被判非法。
      final tree = buildArtifactTree([
        _entry('a.md', path: '/workspace/groups/$_gid/a.md/'),
      ], groupId: _gid);
      expect(tree.single.relativePath, 'a.md');
    });
  });

  // =========================================================================
  group('路径过滤与穿越防御', () {
    test('不属于本 group 的条目被跳过', () {
      final tree = buildArtifactTree([
        _entry('mine.md'),
        _entry('theirs.md', path: '/workspace/groups/$_otherGid/theirs.md/'),
      ], groupId: _gid);

      expect(_paths(tree), ['mine.md']);
    });

    test('不在 workspace/groups 前缀下的路径被跳过', () {
      final tree = buildArtifactTree([
        _entry('mine.md'),
        _entry('x', path: '/etc/passwd/'),
      ], groupId: _gid);
      expect(_paths(tree), ['mine.md']);
    });

    test('穿越路径（..）被拒绝，不进树', () {
      // groupRelativePath 是唯一权威：`..` 会让相对路径逃出 group 子树。
      final tree = buildArtifactTree([
        _entry('mine.md'),
        _entry('evil', path: '/workspace/groups/$_gid/../evil.md/'),
      ], groupId: _gid);
      expect(_paths(tree), ['mine.md']);
    });

    test('含反斜杠的段被拒绝（Windows 上是分隔符）', () {
      final tree = buildArtifactTree([
        _entry('mine.md'),
        _entry('evil', path: '/workspace/groups/$_gid/a\\\\b.md/'),
      ], groupId: _gid);
      expect(_paths(tree), ['mine.md']);
    });

    test('group 根目录自身（无相对部分）被跳过', () {
      final tree = buildArtifactTree([
        _entry('', path: '/workspace/groups/$_gid/'),
      ], groupId: _gid);
      expect(tree, isEmpty);
    });
  });

  // =========================================================================
  group('聚合（计数 / 体积 / 最新时间向上累加到全部祖先）', () {
    test('计数与体积累加到直接父目录', () {
      final tree = buildArtifactTree([
        _entry('reports/a.md', size: 100),
        _entry('reports/b.md', size: 250),
      ], groupId: _gid);

      final reports = _dir(tree, 'reports');
      expect(reports.fileCount, 2);
      expect(reports.totalBytes, 350);
    });

    test('计数与体积穿透多层，累加到全部祖先', () {
      final tree = buildArtifactTree([
        _entry('reports/2026/deep/a.md', size: 100),
      ], groupId: _gid);

      // 三层祖先都应看到这个文件。
      expect(_dir(tree, 'reports').fileCount, 1);
      expect(_dir(tree, 'reports/2026').fileCount, 1);
      expect(_dir(tree, 'reports/2026/deep').fileCount, 1);
      expect(_dir(tree, 'reports').totalBytes, 100);
    });

    test('目录 latestUpdatedAt 取子树内最新，而非自身条目', () {
      final tree = buildArtifactTree([
        _entry('reports/old.md', updatedAt: '2026-01-01T00:00:00Z'),
        _entry('reports/new.md', updatedAt: '2026-03-01T00:00:00Z'),
      ], groupId: _gid);

      final reports = _dir(tree, 'reports');
      expect(
        reports.latestUpdatedAt,
        DateTime.parse('2026-03-01T00:00:00Z').toLocal(),
      );
    });

    test('无 updated_at 的文件不污染目录最新时间', () {
      final tree = buildArtifactTree([
        _entry('reports/known.md', updatedAt: '2026-03-01T00:00:00Z'),
        // 缺 updated_at：解析为 null，不应参与 max。
        UfsFileEntry.fromJson({
          'id': 'no-ts',
          'path': '/workspace/groups/$_gid/reports/unknown.md/',
          'name': 'unknown.md',
          'size': 5,
          'is_directory': false,
        }),
      ], groupId: _gid);

      expect(_dir(tree, 'reports').fileCount, 2, reason: '计数仍应包含它');
      expect(
        _dir(tree, 'reports').latestUpdatedAt,
        DateTime.parse('2026-03-01T00:00:00Z').toLocal(),
      );
    });

    test('空目录（只有目录条目）计数为 0', () {
      final tree = buildArtifactTree([
        _entry('empty', directory: true),
      ], groupId: _gid);

      final empty = _dir(tree, 'empty');
      expect(empty.fileCount, 0);
      expect(empty.totalBytes, 0);
      expect(empty.latestUpdatedAt, isNull);
    });
  });

  // =========================================================================
  group('已删除条目', () {
    test('默认排除软删文件（侧边栏展示「现在有什么」）', () {
      final tree = buildArtifactTree([
        _entry('alive.md'),
        _entry('gone.md', deleted: true),
      ], groupId: _gid);

      expect(_paths(tree), ['alive.md']);
    });

    test('includeDeleted=true 时保留软删文件', () {
      final tree = buildArtifactTree(
        [_entry('alive.md'), _entry('gone.md', deleted: true)],
        groupId: _gid,
        includeDeleted: true,
      );

      expect(_paths(tree), containsAll(['alive.md', 'gone.md']));
    });

    test('默认排除软删的目录条目（不因它凭空造出空目录）', () {
      final tree = buildArtifactTree([
        _entry('stale', directory: true, deleted: true),
      ], groupId: _gid);
      expect(tree, isEmpty);
    });

    test('软删文件的计数不进目录（与展示一致）', () {
      final tree = buildArtifactTree([
        _entry('reports/a.md'),
        _entry('reports/gone.md', deleted: true),
      ], groupId: _gid);
      expect(_dir(tree, 'reports').fileCount, 1);
    });
  });

  // =========================================================================
  group('排序', () {
    test('目录在前、文件在后', () {
      final tree = buildArtifactTree([
        _entry('zzz.md'),
        _entry('aaa/file.md'),
      ], groupId: _gid);

      expect(tree.first, isA<ArtifactDirectoryNode>());
      expect(tree.last, isA<ArtifactFileNode>());
    });

    test('同层按最新时间倒序（新的在前）', () {
      final tree = buildArtifactTree([
        _entry('old.md', updatedAt: '2026-01-01T00:00:00Z'),
        _entry('new.md', updatedAt: '2026-06-01T00:00:00Z'),
        _entry('mid.md', updatedAt: '2026-03-01T00:00:00Z'),
      ], groupId: _gid);

      expect(tree.map((n) => n.relativePath).toList(), [
        'new.md',
        'mid.md',
        'old.md',
      ]);
    });

    test('目录按其子树最新时间排序（不是目录条目自身时间）', () {
      final tree = buildArtifactTree([
        _entry('old-dir', directory: true, updatedAt: '2026-01-01T00:00:00Z'),
        _entry('old-dir/x.md', updatedAt: '2026-01-01T00:00:00Z'),
        _entry('new-dir', directory: true, updatedAt: '2026-01-01T00:00:00Z'),
        _entry('new-dir/y.md', updatedAt: '2026-09-01T00:00:00Z'),
      ], groupId: _gid);

      expect(tree.map((n) => n.relativePath).toList(), ['new-dir', 'old-dir']);
    });

    test('同时间戳按名字大小写不敏感排序（稳定兜底）', () {
      const ts = '2026-01-01T00:00:00Z';
      final tree = buildArtifactTree([
        _entry('Beta.md', updatedAt: ts),
        _entry('alpha.md', updatedAt: ts),
        _entry('Gamma.md', updatedAt: ts),
      ], groupId: _gid);

      expect(tree.map((n) => n.name).toList(), [
        'alpha.md',
        'Beta.md',
        'Gamma.md',
      ]);
    });

    test('排序递归应用到子目录', () {
      final tree = buildArtifactTree([
        _entry('d/old.md', updatedAt: '2026-01-01T00:00:00Z'),
        _entry('d/new.md', updatedAt: '2026-06-01T00:00:00Z'),
      ], groupId: _gid);

      expect(_dir(tree, 'd').children.map((n) => n.name).toList(), [
        'new.md',
        'old.md',
      ]);
    });
  });

  // =========================================================================
  group('展示名', () {
    test('nice_name 优先于文件名', () {
      final tree = buildArtifactTree([
        _entry('raw.md', metadata: {'nice_name': '  产品规格说明书  '}),
      ], groupId: _gid);

      expect((tree.single as ArtifactFileNode).name, '产品规格说明书');
      // relativePath 始终是真实路径，不受 nice_name 影响（下载 / 预览依赖它）。
      expect(tree.single.relativePath, 'raw.md');
    });

    test('nice_name 为空/纯空白时回落到文件名', () {
      final tree = buildArtifactTree([
        _entry('raw.md', metadata: {'nice_name': '   '}),
      ], groupId: _gid);
      expect((tree.single as ArtifactFileNode).name, 'raw.md');
    });

    test('name 为空时回落到路径末段', () {
      final tree = buildArtifactTree([_entry('a.md', name: '')], groupId: _gid);
      expect((tree.single as ArtifactFileNode).name, 'a.md');
    });

    test('目录名取路径末段', () {
      final tree = buildArtifactTree([
        _entry('reports/2026/a.md'),
      ], groupId: _gid);
      expect(_dir(tree, 'reports').name, 'reports');
      expect(_dir(tree, 'reports/2026').name, '2026');
    });
  });

  // =========================================================================
  group('健壮性', () {
    test('同一路径重复条目：当前不去重，但不崩溃（服务端分页边界重叠的防御）', () {
      // 服务端理论上不会重复，但 UFS 分页边界重叠时可能出现。
      // 当前实现保留全部（不静默丢数据）；去重是将来若真出问题再补的事。
      final tree = buildArtifactTree([
        _entry('a.md', id: 'first'),
        _entry('a.md', id: 'second'),
      ], groupId: _gid);

      final files = tree.whereType<ArtifactFileNode>().toList();
      expect(files, hasLength(2));
      expect(files.map((f) => f.file.id), containsAll(['first', 'second']));
    });

    test('深路径不栈溢出（宽度优先创建 + 迭代式遍历）', () {
      final deep = List.generate(60, (i) => 'd$i').join('/');
      final tree = buildArtifactTree([_entry('$deep/leaf.md')], groupId: _gid);

      expect(_paths(tree).length, 61); // 60 层目录 + 1 文件
    });

    test('大量文件不改变结构正确性', () {
      final entries = List.generate(
        500,
        (i) => _entry('batch/f$i.md', updatedAt: '2026-01-01T00:00:00Z'),
      );
      final tree = buildArtifactTree(entries, groupId: _gid);
      expect(_dir(tree, 'batch').fileCount, 500);
    });

    test('返回的树与输入顺序无关（排序规范化）', () {
      final entries = [
        _entry('b.md', updatedAt: '2026-01-01T00:00:00Z'),
        _entry('a.md', updatedAt: '2026-02-01T00:00:00Z'),
      ];
      final forward = buildArtifactTree(entries, groupId: _gid);
      final backward = buildArtifactTree(entries.reversed, groupId: _gid);

      expect(_paths(forward), _paths(backward));
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';

/// 本地同步目录扫描与清理执行测试（**真实文件系统**）。
///
/// ## 这个测试防的是什么
///
/// 这是**删除代码**，而同步目录是**用户自己的目录**。防御失效的后果不是
/// 「报个错」，而是删掉用户的数据。四类必须分别验证：
///
/// 1. **形状准入**：用户自己的目录/文件（`.git`、`notes/`、`README.md`）
///    一律不进入候选；
/// 2. **符号链接**：名为 group_id 的软链可能指向 `~`——跟随删除是灾难；
/// 3. **TOCTOU**：扫描与删除之间路径可能被换成软链，故删除前必须重新校验；
/// 4. **路径越界**：解析后落在 `localRoot` 之外的必须拒绝。
void main() {
  late Directory root;
  late Directory outside;

  setUp(() async {
    // 用真实临时目录：`resolveSymbolicLinks` 与 `list(followLinks: false)`
    // 必须真跑，不能用内存文件系统。
    final base = await Directory.systemTemp.createTemp('spb-prune-');
    root = Directory('${base.path}/root')..createSync(recursive: true);
    outside = Directory('${base.path}/outside')..createSync(recursive: true);
  });

  tearDown(() {
    // 清理整个临时基目录（root 的父目录）。
    final base = root.parent;
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  /// 造一个 group 目录并写入若干文件。
  Directory makeGroup(String gid, {List<String> files = const ['a.md']}) {
    final dir = Directory('${root.path}/$gid')..createSync(recursive: true);
    for (final f in files) {
      final file = File('${dir.path}/$f');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('x' * 10);
    }
    return dir;
  }

  const gidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const gidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  group('scanLocalGroups：只认 group_id 形状的目录', () {
    test('扫出 group 目录并统计文件数与体积', () async {
      makeGroup(gidA, files: ['a.md', 'sub/b.md']);
      makeGroup(gidB);

      final groups = await scanLocalGroups(root.path);

      expect(groups.map((g) => g.groupId).toList(), [gidA, gidB]);
      final a = groups.firstWhere((g) => g.groupId == gidA);
      expect(a.fileCount, 2);
      expect(a.totalBytes, 20);
      expect(a.newestMtime, isNotNull);
    });

    test('用户自己的目录与文件一律不碰', () async {
      makeGroup(gidA);
      // 这些都不符合 32 位小写十六进制形状。
      Directory('${root.path}/.git').createSync();
      Directory('${root.path}/notes').createSync();
      Directory('${root.path}/my-notes').createSync();
      File('${root.path}/README.md').writeAsStringSync('hi');
      // 大写十六进制也不行（Go 侧 NewID 产出小写）。
      Directory('${root.path}/${'A' * 32}').createSync();

      final groups = await scanLocalGroups(root.path);

      expect(groups.length, 1);
      expect(groups.first.groupId, gidA);
    });

    test('目录不存在时返回空（不是错误）', () async {
      expect(await scanLocalGroups('${root.path}/nope'), isEmpty);
    });

    test('排序稳定（文件系统列举顺序不可依赖）', () async {
      // 逆序创建，验证输出仍按 id 升序。
      makeGroup(gidB);
      makeGroup(gidA);
      final groups = await scanLocalGroups(root.path);
      expect(groups.map((g) => g.groupId).toList(), [gidA, gidB]);
    });

    test('空目录的 newestMtime 为 null', () async {
      Directory('${root.path}/$gidA').createSync();
      final groups = await scanLocalGroups(root.path);
      expect(groups.first.fileCount, 0);
      expect(groups.first.newestMtime, isNull);
    });
  });

  group('scanLocalGroups：符号链接防御', () {
    test('名为 group_id 的软链被跳过（不跟随、不统计）', () async {
      // 回归防线：跟随软链会把「删目录」变成「删链接指向的目标」。
      final victim = Directory('${outside.path}/victim')
        ..createSync(recursive: true);
      File('${victim.path}/secret.txt').writeAsStringSync('secret');
      Link('${root.path}/$gidA').createSync(victim.path);

      final groups = await scanLocalGroups(root.path);

      expect(groups, isEmpty, reason: '软链不是真实目录，必须跳过（它的体积是目录外的）');
      // 目标必须完好。
      expect(File('${victim.path}/secret.txt').existsSync(), isTrue);
    });

    test('统计不跟随内部软链（避免统计到目录外）', () async {
      final g = makeGroup(gidA, files: ['a.md']);
      final victim = Directory('${outside.path}/big')..createSync();
      File('${victim.path}/big.bin').writeAsBytesSync(List.filled(10000, 0));
      Link('${g.path}/link-to-big').createSync(victim.path);

      final groups = await scanLocalGroups(root.path);

      expect(groups.length, 1);
      expect(
        groups.first.totalBytes,
        10,
        reason: '只应统计真实文件（10 字节），不得把目录外的大文件算进来',
      );
    });

    test('软链成环不死循环（不跟随即天然免疫）', () async {
      final g = makeGroup(gidA, files: ['a.md']);
      Link('${g.path}/self').createSync(g.path);

      // 若跟随软链，这里会无限递归；有超时保护能暴露问题。
      final groups = await scanLocalGroups(root.path);
      expect(groups.first.fileCount, 1);
    });
  });

  group('scanLocalStats', () {
    test('汇总目录数/文件数/体积', () async {
      makeGroup(gidA, files: ['a.md', 'b.md']);
      makeGroup(gidB, files: ['c.md']);

      final stats = await scanLocalStats(root.path);

      expect(stats.groupCount, 2);
      expect(stats.fileCount, 3);
      expect(stats.totalBytes, 30);
    });

    test('无目录 → 空统计', () async {
      final stats = await scanLocalStats(root.path);
      expect(stats, LocalSyncStats.empty);
      expect(stats.isEmpty, isTrue);
    });

    test('与 scanLocalGroups 用同一套准入规则（不出现「统计 10 个、清理只认 8 个」）', () async {
      makeGroup(gidA);
      Directory('${root.path}/notes').createSync();

      final stats = await scanLocalStats(root.path);
      final groups = await scanLocalGroups(root.path);

      expect(stats.groupCount, groups.length);
    });
  });

  group('executePrunePlan：执行删除', () {
    test('删除候选目录，保留其余', () async {
      final a = makeGroup(gidA);
      final b = makeGroup(gidB);

      final outcome = await executePrunePlan(
        localRoot: root.path,
        plan: const PrunePlan(
          candidates: [
            PruneCandidate(
              groupId: gidA,
              fileCount: 1,
              totalBytes: 10,
              reason: '测试',
            ),
          ],
        ),
      );

      expect(outcome.deleted, 1);
      expect(outcome.hasFailures, isFalse);
      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isTrue, reason: '不在计划里的目录不得被动到');
    });

    test('计划为空时不删任何东西', () async {
      final a = makeGroup(gidA);
      final outcome = await executePrunePlan(
        localRoot: root.path,
        plan: const PrunePlan(),
      );
      expect(outcome.deleted, 0);
      expect(a.existsSync(), isTrue);
    });

    test('用户自己的目录名不在计划里 → 不碰（形状门槛的第二道防线）', () async {
      // 即使有人手工构造了非法 groupId 的计划，执行层也要拒绝。
      final userDir = Directory('${root.path}/my-notes')..createSync();
      final outcome = await executePrunePlan(
        localRoot: root.path,
        plan: const PrunePlan(
          candidates: [
            PruneCandidate(
              groupId: 'my-notes',
              fileCount: 0,
              totalBytes: 0,
              reason: '伪造',
            ),
          ],
        ),
      );

      expect(outcome.deleted, 0);
      expect(outcome.failed.keys, contains('my-notes'));
      expect(userDir.existsSync(), isTrue, reason: '用户目录必须完好');
    });

    test('目录已被删掉 → 幂等成功（不计失败）', () async {
      final outcome = await executePrunePlan(
        localRoot: root.path,
        plan: const PrunePlan(
          candidates: [
            PruneCandidate(
              groupId: gidA,
              fileCount: 0,
              totalBytes: 0,
              reason: '测试',
            ),
          ],
        ),
      );

      expect(outcome.deleted, 0);
      expect(outcome.hasFailures, isFalse, reason: '已不存在不是失败');
    });

    test('TOCTOU：候选路径已被换成软链 → 拒绝删除（不跟随）', () async {
      // 回归防线：扫描时是真目录，用户确认期间被替换成软链。
      final victim = Directory('${outside.path}/victim')
        ..createSync(recursive: true);
      File('${victim.path}/keep.txt').writeAsStringSync('keep');
      Link('${root.path}/$gidA').createSync(victim.path);

      final outcome = await executePrunePlan(
        localRoot: root.path,
        plan: const PrunePlan(
          candidates: [
            PruneCandidate(
              groupId: gidA,
              fileCount: 0,
              totalBytes: 0,
              reason: '测试',
            ),
          ],
        ),
      );

      expect(outcome.deleted, 0);
      expect(outcome.failed.keys, contains(gidA));
      expect(
        File('${victim.path}/keep.txt').existsSync(),
        isTrue,
        reason: '软链目标（目录外）绝不能被删',
      );
    });

    test('TOCTOU：候选路径已被换成普通文件 → 拒绝', () async {
      File('${root.path}/$gidA').writeAsStringSync('not a dir');

      final outcome = await executePrunePlan(
        localRoot: root.path,
        plan: const PrunePlan(
          candidates: [
            PruneCandidate(
              groupId: gidA,
              fileCount: 0,
              totalBytes: 0,
              reason: '测试',
            ),
          ],
        ),
      );

      expect(outcome.deleted, 0);
      expect(outcome.failed.keys, contains(gidA));
      expect(File('${root.path}/$gidA').existsSync(), isTrue);
    });

    test('单个失败不阻断其余（一个权限问题不该让整次清理白跑）', () async {
      makeGroup(gidB);

      final outcome = await executePrunePlan(
        localRoot: root.path,
        plan: const PrunePlan(
          candidates: [
            PruneCandidate(
              groupId: 'my-notes', // 非法形状 → 失败
              fileCount: 0,
              totalBytes: 0,
              reason: '伪造',
            ),
            PruneCandidate(
              groupId: gidB, // 合法 → 应被删掉
              fileCount: 1,
              totalBytes: 10,
              reason: '测试',
            ),
          ],
        ),
      );

      expect(outcome.deleted, 1);
      expect(outcome.failed.length, 1);
      expect(Directory('${root.path}/$gidB').existsSync(), isFalse);
    });

    test('localRoot 不存在 → 空结果（幂等，不是错误）', () async {
      final outcome = await executePrunePlan(
        localRoot: '${root.path}/gone',
        plan: const PrunePlan(
          candidates: [
            PruneCandidate(
              groupId: gidA,
              fileCount: 0,
              totalBytes: 0,
              reason: '测试',
            ),
          ],
        ),
      );
      expect(outcome.deleted, 0);
      expect(outcome.hasFailures, isFalse);
    });

    test('只删 group 目录这一层（不递归删到 localRoot 之上）', () async {
      makeGroup(gidA);
      // localRoot 自己的一个兄弟文件必须幸存。
      File('${root.path}/sibling.txt').writeAsStringSync('sibling');

      await executePrunePlan(
        localRoot: root.path,
        plan: const PrunePlan(
          candidates: [
            PruneCandidate(
              groupId: gidA,
              fileCount: 1,
              totalBytes: 10,
              reason: '测试',
            ),
          ],
        ),
      );

      expect(root.existsSync(), isTrue, reason: 'localRoot 本身不得被删');
      expect(File('${root.path}/sibling.txt').existsSync(), isTrue);
    });
  });
}

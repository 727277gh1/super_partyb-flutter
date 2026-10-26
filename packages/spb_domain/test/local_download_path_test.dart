import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 「下载到本地 → 落地相对路径」映射（[deliverableDownloadRelPath] /
/// [agentFileDownloadRelPath]）测试。
///
/// ## 这个测试防的是什么
///
/// 它决定「下载的文件最终落在磁盘的哪个位置」。失败模式全是**静默**的
/// ——不崩溃、不报错，只是文件不见了、或别人的文件被覆盖：
///
/// - **平铺**（修复前的状态）→ 每个 group 都有自己的 `README.md`，第二个
///   group 下载完会盖掉第一个，用户看到「下载完内容变了」；
/// - **丢目录结构** → `reports/a.md` 被压成 `a.md`，用户按面板显示的树形
///   路径去找必然找不到；
/// - **没有 groupId 段** → 磁盘上分不清文件属于哪个对话；
/// - **路径穿越** → `..` 让写入逃出下载目录（覆盖 `~/.ssh/authorized_keys`）；
/// - **两端各写一份** → 桌面端改了移动端没改（这就是为什么口径收敛到
///   `spb_domain` 的纯函数里）。
///
/// 故逐条钉死：groupId 段 / 保留子目录 / 尾斜杠 / 穿越退化 / 非交付物路径 /
/// 两段来源非法时的兜底。
const gidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

UfsFileEntry entry({required String path, String? name, String id = 'ufs_1'}) =>
    UfsFileEntry.fromJson({
      'id': id,
      'path': path,
      'size': 1,
      'name': name ?? path.split('/').where((s) => s.isNotEmpty).last,
      'is_directory': false,
    });

AgentFileItem agentFile({
  required String relPath,
  String? fileName,
  String? ufsFileId = 'ufs_1',
}) => AgentFileItem(
  id: relPath,
  createdAt: DateTime.utc(2026, 1, 1),
  relativePath: relPath,
  fileName: fileName ?? relPath.split('/').last,
  displayName: fileName ?? relPath.split('/').last,
  action: 'created',
  ufsFileId: ufsFileId,
);

void main() {
  group('deliverableDownloadRelPath（交付物面板的下载）', () {
    test('带上 groupId 段，并保留 group 内目录结构', () {
      expect(
        deliverableDownloadRelPath(
          entry(path: '/workspace/groups/$gidA/reports/a.md/'),
        ),
        '$gidA/reports/a.md',
      );
    });

    test('UFS 物化路径对文件也带尾斜杠（不剥掉会得到空文件名）', () {
      // 服务端 `buildMaterializedPath` 无条件拼 `name + '/'`，实测
      // `/workspace/groups/{gid}/README.md/`。
      expect(
        deliverableDownloadRelPath(
          entry(path: '/workspace/groups/$gidA/README.md/'),
        ),
        '$gidA/README.md',
      );
    });

    test('深层目录逐段保留（面板显示树形路径，落地必须一致）', () {
      expect(
        deliverableDownloadRelPath(
          entry(path: '/workspace/groups/$gidA/a/b/c/d.json/'),
        ),
        '$gidA/a/b/c/d.json',
      );
    });

    test('不在 /workspace/groups/ 下的路径退化为单文件名（不报错）', () {
      // 非交付物文件（例如用户自己上传到别处的）：仍要能下载到，只是没有
      // groupId 段。用「报错」处理会让下载永久失败。
      expect(
        deliverableDownloadRelPath(entry(path: '/other/place/x.md')),
        'x.md',
      );
    });

    test('group 根目录自身（只有 groupId 没有文件名）退化为单文件名', () {
      expect(
        deliverableDownloadRelPath(
          entry(path: '/workspace/groups/$gidA/', name: 'placeholder.md'),
        ),
        'placeholder.md',
      );
    });

    test('路径穿越（..）被拒绝，退化为单文件名而非写到目录之外', () {
      final rel = deliverableDownloadRelPath(
        entry(path: '/workspace/groups/$gidA/../../../etc/passwd'),
      );
      expect(rel, 'passwd');
      expect(rel.contains('..'), isFalse);
    });

    test('段内反斜杠被拒绝（Windows 上 \\ 是目录分隔符，能绕过段级校验）', () {
      final rel = deliverableDownloadRelPath(
        entry(path: r'/workspace/groups/aaa\..\..\evil/a.md'),
      );
      expect(rel.contains(r'\'), isFalse);
      expect(rel.contains('..'), isFalse);
    });

    test('name 为空时用 path 的最后一段', () {
      final f = UfsFileEntry.fromJson({
        'id': 'ufs_9',
        'path': '/workspace/groups/$gidA/reports/a.md/',
        'size': 1,
        'name': '',
        'is_directory': false,
      });
      expect(deliverableDownloadRelPath(f), '$gidA/reports/a.md');
    });

    test('两个不同 group 的同名文件落到不同目录（不再互相覆盖）', () {
      const gidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final a = deliverableDownloadRelPath(
        entry(path: '/workspace/groups/$gidA/README.md/'),
      );
      final b = deliverableDownloadRelPath(
        entry(path: '/workspace/groups/$gidB/README.md/'),
      );
      expect(a, isNot(b), reason: '修复前两者都是 README.md，后者覆盖前者');
    });
  });

  group('agentFileDownloadRelPath（时间线内联卡的下载）', () {
    test('带上 groupId 段，并保留 relativePath 的目录结构', () {
      expect(
        agentFileDownloadRelPath(agentFile(relPath: 'reports/a.md'), gidA),
        '$gidA/reports/a.md',
      );
    });

    test('相对路径已归一化（无首尾斜杠），不重复剥前缀', () {
      // 归约器已归一化；这里若再剥 `/workspace/groups/{gid}/` 会把一个合法的
      // 相对路径 `workspace/x` 削掉一截。
      expect(
        agentFileDownloadRelPath(agentFile(relPath: 'workspace/x.md'), gidA),
        '$gidA/workspace/x.md',
      );
    });

    test('相对路径含 .. 时退化为单文件名（不逃出下载目录）', () {
      final rel = agentFileDownloadRelPath(
        agentFile(relPath: '../../etc/passwd', fileName: 'passwd'),
        gidA,
      );
      expect(rel, '$gidA/passwd');
      expect(rel.contains('..'), isFalse);
    });

    test('relativePath 为空时用 fileName 兜底', () {
      expect(
        agentFileDownloadRelPath(
          agentFile(relPath: '', fileName: 'QWEN.md'),
          gidA,
        ),
        '$gidA/QWEN.md',
      );
    });

    test('fileName 为空时用 agent-file 占位（而不是空文件名）', () {
      expect(
        agentFileDownloadRelPath(
          agentFile(relPath: 'reports/a.md', fileName: ''),
          gidA,
        ),
        '$gidA/reports/a.md',
      );
    });

    test('groupId 非法（含 ..）时省略该段，但仍不逃出下载目录', () {
      final rel = agentFileDownloadRelPath(
        agentFile(relPath: 'a.md'),
        '../../evil',
      );
      expect(rel, 'a.md');
      expect(rel.contains('..'), isFalse);
    });

    test('两个不同 group 的同名文件落到不同目录', () {
      const gidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final a = agentFileDownloadRelPath(agentFile(relPath: 'QWEN.md'), gidA);
      final b = agentFileDownloadRelPath(agentFile(relPath: 'QWEN.md'), gidB);
      expect(a, isNot(b));
    });
  });
}

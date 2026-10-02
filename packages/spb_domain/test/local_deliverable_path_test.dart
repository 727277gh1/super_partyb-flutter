import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 「已同步交付物 → 本地相对路径」映射（[resolveLocalDeliverablePath]）测试。
///
/// ## 这个测试防的是什么
///
/// 它决定「点『打开』时交给系统程序的是哪个文件」。失败模式全是**静默**的
/// ——不崩溃、不报错，只是打开了错误的东西或什么都没打开：
///
/// - **未同步却报已同步** → 打开一个不存在的路径，用户以为文件坏了；
/// - **跨 group 串号** → A 组的 `README.md` 命中 B 组的记录，打开的是**另一个
///   对话**的内容（信息泄漏 + 误导）；
/// - **路径穿越** → `..` 让映射结果逃出同步目录；
/// - **布局错配** → workspace 状态配单 group 布局，同名前缀互相命中。
///
/// 故逐条钉死：命中 / 未同步 / 穿越 / 跨 group / 两种布局。
const gidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const gidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// 构造一个「已同步了若干相对路径」的状态。
SyncState stateWith(List<String> relPaths) => SyncState(
  files: {for (final rel in relPaths) rel: const SyncedFile(size: 1)},
);

String ufsPath(String gid, String rel) => '/workspace/groups/$gid/$rel/';

void main() {
  // =========================================================================
  group('workspace 布局（全部 / 选中若干 group）', () {
    test('已同步的路径命中，返回含 groupId 的相对路径', () {
      final state = stateWith(['$gidA/reports/spec.md']);
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          ufsPath(gidA, 'reports/spec.md'),
        ),
        '$gidA/reports/spec.md',
      );
    });

    test('未同步返回 null（不能打开一个不存在的文件）', () {
      final state = stateWith(['$gidA/reports/other.md']);
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          ufsPath(gidA, 'reports/spec.md'),
        ),
        isNull,
      );
    });

    test('空状态一律返回 null', () {
      expect(
        resolveLocalDeliverablePath(
          SyncState.empty,
          gidA,
          ufsPath(gidA, 'README.md'),
        ),
        isNull,
      );
    });

    test('跨 group 不串号：A 组同步过，B 组同名文件仍是未同步', () {
      // 这正是 workspace 布局必须带 {groupId}/ 前缀的原因。
      final state = stateWith(['$gidA/README.md']);
      expect(
        resolveLocalDeliverablePath(state, gidB, ufsPath(gidB, 'README.md')),
        isNull,
        reason: 'B 组的 README 不应命中 A 组的记录',
      );
      // A 组自己仍命中。
      expect(
        resolveLocalDeliverablePath(state, gidA, ufsPath(gidA, 'README.md')),
        '$gidA/README.md',
      );
    });

    test('groupId 与路径不一致时返回 null（不打开别的对话的文件）', () {
      // 调用方声明 gidB，但 ufsPath 属于 gidA —— 路径里的 groupId 以 ufsPath
      // 为准，若不做比对就会返回 gidA 的路径，于是面板打开**另一个对话**的文件。
      final state = stateWith(['$gidA/README.md']);
      expect(
        resolveLocalDeliverablePath(state, gidB, ufsPath(gidA, 'README.md')),
        isNull,
      );
    });

    test('空 groupId 返回 null（前缀会退化成 /workspace/groups//）', () {
      final state = stateWith(['$gidA/README.md']);
      expect(
        resolveLocalDeliverablePath(state, '', ufsPath(gidA, 'README.md')),
        isNull,
      );
    });
  });

  // =========================================================================
  group('单 group 布局', () {
    const layout = DeliverableSyncLayout.singleGroup;

    test('已同步命中，返回**不含** groupId 的相对路径', () {
      // 单 group 模式剥掉 {gid}/ 前缀（本地直接是 group 内容）。
      final state = stateWith(['reports/spec.md']);
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          ufsPath(gidA, 'reports/spec.md'),
          layout: layout,
        ),
        'reports/spec.md',
      );
    });

    test('未同步返回 null', () {
      final state = stateWith(['reports/other.md']);
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          ufsPath(gidA, 'reports/spec.md'),
          layout: layout,
        ),
        isNull,
      );
    });

    test('布局错配会串号（钉住「状态键必须与布局配对」这条约束）', () {
      // 把 workspace 布局的状态（键为 __workspace__，路径含 {gid}/）喂给
      // 单 group 布局：A 组的 README 记录是 'gidA/README.md'，而单 group 布局
      // 算出的相对路径是 'README.md'，两者**不相等** → 查不到（安全的一侧）。
      final workspaceState = stateWith(['$gidA/README.md']);
      expect(
        resolveLocalDeliverablePath(
          workspaceState,
          gidA,
          ufsPath(gidA, 'README.md'),
          layout: layout,
        ),
        isNull,
        reason: '布局错配应查不到，而不是错误命中',
      );
    });
  });

  // =========================================================================
  group('路径穿越防御', () {
    // 穿越路径**不可能**出现在同步索引里（同步器在计划期就拒掉了），故这里
    // 的真实风险是「调用方传入未校验的路径」。断言返回 null（拒绝），而不是
    // 返回一个拼接出来的逃逸路径。
    final state = stateWith([
      'reports/spec.md',
      'gidA/reports/spec.md',
      '../secret.md',
      'x/../../secret.md',
    ]);

    test('.. 路径被拒绝', () {
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/../secret.md/',
        ),
        isNull,
      );
    });

    test('嵌套 .. 被拒绝', () {
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/x/../../secret.md/',
        ),
        isNull,
      );
    });

    test('单 group 布局下 .. 同样被拒绝', () {
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/../secret.md/',
          layout: DeliverableSyncLayout.singleGroup,
        ),
        isNull,
      );
    });

    test('. 与空段被拒绝', () {
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/./x/',
        ),
        isNull,
      );
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/a//b/',
        ),
        isNull,
      );
    });

    test('反斜杠（Windows 分隔符）被拒绝', () {
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/a\\\\b/',
        ),
        isNull,
      );
    });

    test('NUL 被拒绝', () {
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/a\u0000b/',
        ),
        isNull,
      );
    });

    test('group 根目录自身（不是文件）返回 null', () {
      expect(
        resolveLocalDeliverablePath(state, gidA, '/workspace/groups/$gidA/'),
        isNull,
      );
    });

    test('不属于该 group 的路径返回 null', () {
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/other/reports/spec.md/',
        ),
        isNull,
      );
      expect(
        resolveLocalDeliverablePath(state, gidA, '/somewhere/else.md/'),
        isNull,
      );
    });
  });

  // =========================================================================
  group('尾斜杠（UFS 实测对文件也带尾斜杠）', () {
    test('带尾斜杠的 UFS 路径能正常命中', () {
      // UFS 的 buildMaterializedPath 无条件拼 name + '/'，实测文件路径形如
      // .../README.md/。不剥尾斜杠的话尾段为空，全部文件都会被判非法。
      final state = stateWith(['$gidA/README.md']);
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/README.md/',
        ),
        '$gidA/README.md',
      );
    });

    test('多个尾斜杠也能命中', () {
      final state = stateWith(['$gidA/README.md']);
      expect(
        resolveLocalDeliverablePath(
          state,
          gidA,
          '/workspace/groups/$gidA/README.md///',
        ),
        '$gidA/README.md',
      );
    });
  });
}

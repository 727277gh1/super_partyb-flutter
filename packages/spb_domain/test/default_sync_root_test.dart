import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// [defaultSyncLocalRoot] 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 默认同步目录取错的后果是**静默**的：文件都同步成功了，只是落在用户找不到
/// 的地方（隐藏的 `.local/share`，或某台机器上不存在的 `~/Documents`）。
/// 而它的四个分支（覆盖 / Documents / 应用数据目录 / 无 home）在真实环境里
/// 不可能都走一遍——本机有 `~/Documents`，CI 容器没有。
void main() {
  group('defaultSyncLocalRoot', () {
    test('SPB_SYNC_ROOT 覆盖一切（便携部署 / 运维指定）', () {
      expect(
        defaultSyncLocalRoot(
          environment: {
            'SPB_SYNC_ROOT': '/mnt/usb/deliverables',
            'HOME': '/home/u',
            'XDG_DATA_HOME': '/xdg',
          },
          isWindows: false,
          documentsExists: true,
        ),
        '/mnt/usb/deliverables',
      );
    });

    test('空白的 SPB_SYNC_ROOT 不算覆盖', () {
      expect(
        defaultSyncLocalRoot(
          environment: {'SPB_SYNC_ROOT': '  ', 'HOME': '/home/u'},
          isWindows: false,
          documentsExists: true,
        ),
        '/home/u/Documents/Super PartyB',
      );
    });

    test('Linux：~/Documents 存在时优先用它（用户能直接打开）', () {
      expect(
        defaultSyncLocalRoot(
          environment: {'HOME': '/home/u', 'XDG_DATA_HOME': '/xdg'},
          isWindows: false,
          documentsExists: true,
        ),
        '/home/u/Documents/$defaultSyncFolderName',
      );
    });

    test('Linux：无 ~/Documents 时落到应用数据目录（不隐藏语义之外的选择）', () {
      expect(
        defaultSyncLocalRoot(
          environment: {'HOME': '/home/u', 'XDG_DATA_HOME': '/xdg'},
          isWindows: false,
          documentsExists: false,
        ),
        '/xdg/super_partyb/deliverables',
      );
      expect(
        defaultSyncLocalRoot(
          environment: {'HOME': '/home/u'},
          isWindows: false,
          documentsExists: false,
        ),
        '/home/u/.local/share/super_partyb/deliverables',
      );
    });

    test('Windows：USERPROFILE + Documents', () {
      expect(
        defaultSyncLocalRoot(
          environment: {
            'USERPROFILE': r'C:\Users\me',
            'APPDATA': r'C:\Roaming',
          },
          isWindows: true,
          documentsExists: true,
        ),
        r'C:\Users\me/Documents/Super PartyB',
      );
    });

    test('Windows：文档被重定向（本地无 Documents）时落到 APPDATA', () {
      expect(
        defaultSyncLocalRoot(
          environment: {
            'USERPROFILE': r'C:\Users\me',
            'APPDATA': r'C:\Roaming',
          },
          isWindows: true,
          documentsExists: false,
        ),
        r'C:\Roaming/super_partyb/deliverables',
      );
      // 连 APPDATA 都没有：退回约定位置。
      expect(
        defaultSyncLocalRoot(
          environment: {'USERPROFILE': r'C:\Users\me'},
          isWindows: true,
          documentsExists: false,
        ),
        r'C:\Users\me/AppData/Roaming/super_partyb/deliverables',
      );
    });

    test('Windows 不读 HOME / XDG_DATA_HOME（那是 Linux 的变量）', () {
      expect(
        defaultSyncLocalRoot(
          environment: {
            'HOME': '/home/u',
            'XDG_DATA_HOME': '/xdg',
            'USERPROFILE': r'C:\Users\me',
          },
          isWindows: true,
          documentsExists: true,
        ),
        r'C:\Users\me/Documents/Super PartyB',
      );
    });

    test('连 home 都没有 → null（调用方按「未配置」处理，不崩）', () {
      expect(
        defaultSyncLocalRoot(environment: const {}, isWindows: false),
        isNull,
      );
      expect(
        defaultSyncLocalRoot(
          environment: const {},
          isWindows: true,
          documentsExists: true,
        ),
        isNull,
        reason: 'documentsExists 为真但没有 home 也拼不出路径',
      );
    });

    test('路径用 / 分隔（Windows 上 Dart 的 File/Directory 同样接受）', () {
      final root = defaultSyncLocalRoot(
        environment: {'USERPROFILE': r'C:\Users\me'},
        isWindows: true,
        documentsExists: true,
      );
      expect(root, endsWith('/Documents/Super PartyB'));
      expect(root, isNot(contains('\\\\')));
    });
  });
}

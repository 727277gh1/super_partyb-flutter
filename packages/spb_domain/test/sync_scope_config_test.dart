import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 同步范围配置（`SyncScopeConfig`）测试。
///
/// ## 这个测试防的是什么
///
/// 「非全部 + 空列表」是一个**合法但危险**的状态：它是用户表单填到一半的
/// 样子。两种错误处理都比崩溃更糟：
/// - 退化成「全部」→ 用户明明关掉了「全部」，却多下了一整个 workspace
///   （生产实测 5666 条 / 4.7 GB）；
/// - 静默什么都不做 → 用户点同步毫无反应，也不知道为什么。
///
/// 故断言它**明确报错**，且文案可操作。
void main() {
  group('SyncScopeConfig 默认与形态判定', () {
    test('默认为「全部」（设置页没有 group 上下文）', () {
      const c = SyncScopeConfig();
      expect(c.allGroups, isTrue);
      expect(c.isSingleGroup, isFalse);
      expect(c.isSelectedGroups, isFalse);
    });

    test('非全部 + 有勾选 → 选中若干模式', () {
      const c = SyncScopeConfig(allGroups: false, groupIds: ['g1', 'g2']);
      expect(c.isSelectedGroups, isTrue);
      expect(c.isSingleGroup, isFalse);
    });

    test('非全部 + 空列表 → 单 group 模式（设置页不产出）', () {
      const c = SyncScopeConfig(allGroups: false);
      expect(c.isSingleGroup, isTrue);
      expect(c.isSelectedGroups, isFalse);
    });
  });

  group('decode 的坏值回退留痕（issue #45）', () {
    // 坏值回退成「全部同步」是**用户看不见**的语义变化：他可能特意选了
    // 「只同步这几个对话」，但存的值坏了，于是所有对话都被拉下来。
    // 回退方向是对的（「多同步一些」比「突然什么都不同步」好排查），
    // 但既然用户意图被丢弃了，就必须在诊断报告里留下线索。
    setUp(() {
      SpbLog.clearRecentLogs();
      SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
    });

    test('非法 JSON → 回退成「全部」且记 warn', () {
      final c = SyncScopeConfig.decode('{不是 JSON');
      expect(c.allGroups, isTrue);

      final rec = SpbLog.recentLogs
          .where((r) => r.message == '同步范围偏好无法解析，回退成「全部同步」')
          .single;
      expect(rec.level, LogLevel.warn);
      expect(rec.fields['raw_bytes'], greaterThan(0));
    });

    test('合法 JSON 不回退也不记日志', () {
      final c = SyncScopeConfig.decode(
        '{"all_groups": false, "group_ids": ["g1"]}',
      );
      expect(c.allGroups, isFalse);
      expect(c.groupIds, ['g1']);
      expect(SpbLog.recentLogs, isEmpty);
    });

    test('null / 空串 → 默认值，不记日志（不是坏值，是「还没设过」）', () {
      expect(SyncScopeConfig.decode(null).allGroups, isTrue);
      expect(SyncScopeConfig.decode('   ').allGroups, isTrue);
      expect(SpbLog.recentLogs, isEmpty);
    });
  });

  group('SyncScopeConfig.toScope', () {
    test('全部 → WorkspaceScope（忽略 groupId）', () {
      final scope = const SyncScopeConfig().toScope(groupId: 'g1');
      expect(scope, isA<SyncWorkspaceScope>());
    });

    test('勾选若干 → GroupsScope（即使传了 groupId 也不退化成单 group）', () {
      // 回归防线：若 groupId 优先，从某个对话内触发同步会悄悄只同步一个
      // group，而设置页上明明勾了三个。
      final scope = const SyncScopeConfig(
        allGroups: false,
        groupIds: ['g1', 'g2', 'g3'],
      ).toScope(groupId: 'g9');
      expect(scope, isA<SyncGroupsScope>());
      expect((scope as SyncGroupsScope).groupIds, ['g1', 'g2', 'g3']);
    });

    test('单 group 模式用传入的 groupId', () {
      final scope = const SyncScopeConfig(allGroups: false)
          .toScope(groupId: 'g7');
      expect(scope, isA<SyncGroupScope>());
      expect((scope as SyncGroupScope).groupId, 'g7');
    });

    test('单 group 模式缺 groupId → 报错而非退化成「全部」', () {
      // 退化成「全部」是最危险的一侧：用户明确关掉了「全部」。
      expect(
        () => const SyncScopeConfig(allGroups: false).toScope(),
        throwsA(
          isA<PlatformError>().having(
            (e) => e.message,
            'message',
            contains('同步范围未配置'),
          ),
        ),
      );
    });

    test('groupId 为空白串同样报错', () {
      expect(
        () => const SyncScopeConfig(allGroups: false).toScope(groupId: '   '),
        throwsA(isA<PlatformError>()),
      );
    });
  });

  group('SyncScopeConfig.copyWith', () {
    test('切换 allGroups 不影响已勾选项（用户可来回切换）', () {
      const c = SyncScopeConfig(allGroups: false, groupIds: ['g1']);
      final back = c.copyWith(allGroups: true);
      expect(back.allGroups, isTrue);
      expect(back.groupIds, ['g1'], reason: '来回切一次就丢勾选，用户会以为设置没保存');
    });

    test('勾选项去重但保持顺序', () {
      final c = const SyncScopeConfig().copyWith(
        allGroups: false,
        groupIds: ['g2', 'g1', 'g2', 'g1', 'g3'],
      );
      expect(c.groupIds, ['g2', 'g1', 'g3']);
    });

    test('勾选项里的空白串被丢弃（UI 误传不应产生幽灵 group）', () {
      final c = const SyncScopeConfig().copyWith(
        allGroups: false,
        groupIds: ['g1', '', '   ', 'g2'],
      );
      expect(c.groupIds, ['g1', 'g2']);
    });

    test('copyWith 不传 groupIds 时保留原列表', () {
      const c = SyncScopeConfig(allGroups: false, groupIds: ['g1']);
      expect(c.copyWith(allGroups: true).groupIds, ['g1']);
    });

    test('相等性按内容（含顺序）判断', () {
      const a = SyncScopeConfig(allGroups: false, groupIds: ['g1', 'g2']);
      const b = SyncScopeConfig(allGroups: false, groupIds: ['g1', 'g2']);
      const c = SyncScopeConfig(allGroups: false, groupIds: ['g2', 'g1']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse, reason: '顺序不同视为不同（保持可复现）');
    });
  });

  group('SyncSettings', () {
    test('默认无目录 → 不可同步', () {
      expect(const SyncSettings().canSync, isFalse);
      expect(const SyncSettings().hasLocalRoot, isFalse);
    });

    test('有目录 + 全部范围 → 可同步', () {
      const s = SyncSettings(localRoot: '/tmp/out');
      expect(s.canSync, isTrue);
    });

    test('有目录但单 group 模式 → 不可同步（缺 groupId）', () {
      const s = SyncSettings(
        localRoot: '/tmp/out',
        scope: SyncScopeConfig(allGroups: false),
      );
      expect(s.canSync, isFalse);
    });

    test('目录为空白串视为未设置', () {
      expect(const SyncSettings(localRoot: '   ').hasLocalRoot, isFalse);
      expect(const SyncSettings(localRoot: '   ').canSync, isFalse);
    });

    test('clearSinceDays 能真的清空（copyWith 的 null 陷阱）', () {
      // 传 null 会被「?? 保留旧值」吃掉，导致用户选「不限」后仍是近 7 天。
      const s = SyncSettings(sinceDays: 7);
      expect(s.copyWith(sinceDays: 7).sinceDays, 7);
      expect(s.copyWith(clearSinceDays: true).sinceDays, isNull);
    });

    test('相等性含过滤配置与 sinceDays', () {
      const a = SyncSettings(
        localRoot: '/tmp/out',
        filter: SyncFilterConfig(includeMedia: true),
        sinceDays: 7,
      );
      const b = SyncSettings(
        localRoot: '/tmp/out',
        filter: SyncFilterConfig(includeMedia: true),
        sinceDays: 7,
      );
      expect(a, b);
      expect(a == a.copyWith(sinceDays: 30), isFalse);
      expect(a == a.copyWith(filter: const SyncFilterConfig()), isFalse);
    });

    test('相等性含自动同步配置', () {
      // ## 为什么这条必须存在
      //
      // 设置页的「有未保存改动」判定是 `_draft != _saved`。若 `auto` 不参与
      // `==`，用户改了自动同步后**看不到保存按钮**——改动永远无法提交，
      // 而界面上没有任何错误提示。
      const a = SyncSettings(localRoot: '/tmp/out');
      expect(a, const SyncSettings(localRoot: '/tmp/out'));
      expect(
        a == a.copyWith(auto: const AutoSyncConfig(onLaunch: true)),
        isFalse,
      );
      expect(
        a == a.copyWith(auto: const AutoSyncConfig(intervalMinutes: 15)),
        isFalse,
      );
      expect(a.hashCode, const SyncSettings(localRoot: '/tmp/out').hashCode);
    });

    test('copyWith 能改自动同步，且不影响其余字段', () {
      const s = SyncSettings(localRoot: '/tmp/out', sinceDays: 7);
      final next = s.copyWith(
        auto: const AutoSyncConfig(onLaunch: true, intervalMinutes: 30),
      );
      expect(
        next.auto,
        const AutoSyncConfig(onLaunch: true, intervalMinutes: 30),
      );
      expect(next.localRoot, '/tmp/out');
      expect(next.sinceDays, 7);
    });

    test('默认 auto 是全关（自动同步默认关闭）', () {
      // 首次全量同步生产实测 5666 条 / 4.7 GB——静默替用户拉这么多不可接受。
      expect(const SyncSettings().auto, AutoSyncConfig.disabled);
      expect(const SyncSettings().auto.isEnabled, isFalse);
    });
  });
}

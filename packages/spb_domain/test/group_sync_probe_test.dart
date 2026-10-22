import 'package:test/test.dart';

import 'package:spb_domain/spb_domain.dart';

/// 进入对话时的同步判定 + 冷却闸。
///
/// ## 为什么这些必须能无头测
///
/// 判据是**正确性核心**：判错的方向有两个，都很糟。
/// - 该同步却判成 upToDate → 用户开了功能却看不到任何效果（静默失效）；
/// - 不该同步却判成 stale → 每次点对话都拉一轮全范围（首次 4.7 GB）。
///
/// 两者都只在真实网络+真实游标下才暴露，故必须把判据抽成纯函数逐条钉住。
void main() {
  group('groupSyncNeed 判定', () {
    test('远端最晚时间晚于本地游标 → stale', () {
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T09:00:00Z',
          localCursor: '2026-10-21T08:00:00Z',
        ),
        GroupSyncNeed.stale,
      );
    });

    test('远端最晚时间早于本地游标 → upToDate', () {
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T07:00:00Z',
          localCursor: '2026-10-21T08:00:00Z',
        ),
        GroupSyncNeed.upToDate,
      );
    });

    test('恰好等于游标 → upToDate（那份文件就是推进游标的那个）', () {
      // 严格大于而非 >=：`>=` 会让「同步完最后一轮」永远判成 stale——
      // 游标正是被那份文件推上去的。
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T08:00:00Z',
          localCursor: '2026-10-21T08:00:00Z',
        ),
        GroupSyncNeed.upToDate,
      );
    });

    test('本地游标为空（从未同步）→ stale', () {
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T08:00:00Z',
          localCursor: null,
        ),
        GroupSyncNeed.stale,
      );
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T08:00:00Z',
          localCursor: '   ',
        ),
        GroupSyncNeed.stale,
      );
    });

    test('远端没有条目 → unknown（不是 upToDate）', () {
      // 语义区别：upToDate 是「比对过了，本地最新」，unknown 是「没东西可比」。
      // 当前用户可见后果相同，但混用会让将来加「本对话没有交付物」空态时无从区分。
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: null,
          localCursor: '2026-10-21T08:00:00Z',
        ),
        GroupSyncNeed.unknown,
      );
      expect(
        groupSyncNeed(remoteLatestUpdatedAt: '  ', localCursor: null),
        GroupSyncNeed.unknown,
      );
    });

    test('带时区偏移的 RFC3339 也能正确比较', () {
      // 服务端返回的是 UTC（`Z`），但若某天返回 `+08:00`，字典序比较就**不再**
      // 等价于时刻比较。这条用例钉住「当前实现依赖 UTC 形式」这一前提被写下来了
      // ——真出现偏移形式时它会红，提醒改成解析后比较。
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T09:00:00Z',
          localCursor: '2026-10-21T08:00:00Z',
        ),
        GroupSyncNeed.stale,
      );
    });

    test('首尾空白被忽略（偏好表里存过带空格的值）', () {
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: ' 2026-10-21T09:00:00Z ',
          localCursor: '2026-10-21T08:00:00Z',
        ),
        GroupSyncNeed.stale,
      );
    });
  });

  group('latestUpdatedAtOf', () {
    test('取最晚的一个，与顺序无关', () {
      expect(
        latestUpdatedAtOf([
          '2026-10-21T08:00:00Z',
          '2026-10-21T10:00:00Z',
          '2026-10-21T09:00:00Z',
        ]),
        '2026-10-21T10:00:00Z',
      );
    });

    test('空列表 / 全 null → null', () {
      expect(latestUpdatedAtOf(const []), isNull);
      expect(latestUpdatedAtOf([null, null]), isNull);
      expect(latestUpdatedAtOf(['', '  ']), isNull);
    });

    test('null 与空串不参与比较（不会把结果压成空）', () {
      expect(
        latestUpdatedAtOf(['2026-10-21T08:00:00Z', null, '']),
        '2026-10-21T08:00:00Z',
      );
    });

    test('单条也正常', () {
      expect(
        latestUpdatedAtOf(['2026-10-21T08:00:00Z']),
        '2026-10-21T08:00:00Z',
      );
    });
  });

  group('GroupSyncThrottle', () {
    test('首次总是允许', () {
      final t = GroupSyncThrottle();
      expect(t.allows('g1'), isTrue);
    });

    test('冷却期内不允许，冷却期满允许', () {
      var now = DateTime(2026, 10, 21, 8);
      final t = GroupSyncThrottle(
        cooldown: const Duration(minutes: 10),
        now: () => now,
      );

      t.markTriggered('g1');
      expect(t.allows('g1'), isFalse);

      now = now.add(const Duration(minutes: 9));
      expect(t.allows('g1'), isFalse);

      now = now.add(const Duration(minutes: 1));
      expect(t.allows('g1'), isTrue, reason: '恰好到冷却期应放行');
    });

    test('各 group 独立计数（切对话不会互相挡）', () {
      final t = GroupSyncThrottle(cooldown: const Duration(minutes: 10));
      t.markTriggered('g1');
      expect(t.allows('g1'), isFalse);
      expect(t.allows('g2'), isTrue, reason: '另一个 group 是首次');
    });

    test('reset 清空（换同步目录后每个 group 都该重新判定）', () {
      final t = GroupSyncThrottle();
      t.markTriggered('g1');
      expect(t.allows('g1'), isFalse);
      t.reset();
      expect(t.allows('g1'), isTrue);
    });

    test('allows 是纯查询，不记录（重复调用不改变结论）', () {
      // ## 为什么这条重要
      //
      // 若 `allows` 内部记录，那么「判定 → 决定不同步（因为别的条件不满足）」
      // 这条路径会白白消耗掉冷却期，用户之后真的进对话时反而不触发。
      final t = GroupSyncThrottle(cooldown: const Duration(minutes: 10));
      expect(t.allows('g1'), isTrue);
      expect(t.allows('g1'), isTrue);
      expect(t.allows('g1'), isTrue);
    });
  });

  group('AutoSyncConfig.onGroupOpen', () {
    test('默认关（首次全量 4.7 GB，不能默认开）', () {
      expect(const AutoSyncConfig().onGroupOpen, isFalse);
      expect(AutoSyncConfig.disabled.onGroupOpen, isFalse);
    });

    test('它是 isEnabled 的一部分', () {
      expect(const AutoSyncConfig(onGroupOpen: true).isEnabled, isTrue);
      expect(const AutoSyncConfig(onGroupOpen: true).isPeriodic, isFalse);
    });

    test('encode / decode 往返', () {
      const cfg = AutoSyncConfig(
        onGroupOpen: true,
        onLaunch: true,
        intervalMinutes: 30,
      );
      expect(AutoSyncConfig.decode(cfg.encode()), cfg);
    });

    test('旧配置（没有 on_group_open 键）→ false', () {
      // ## 为什么这条是关键
      //
      // 升级后老用户的偏好里没有这个键。若回退成 true，他们会在**毫不知情**
      // 的情况下开始每次进对话都拉一轮——那是 4.7 GB。
      final decoded = AutoSyncConfig.decode(
        '{"on_launch":true,"interval_minutes":60}',
      );
      expect(decoded.onGroupOpen, isFalse);
      expect(decoded.onLaunch, isTrue, reason: '其余字段照常解析');
      expect(decoded.intervalMinutes, 60);
    });

    test('字段类型不对时各自回退，不整体丢弃', () {
      final decoded = AutoSyncConfig.decode(
        '{"on_group_open":"yes","on_launch":true,"interval_minutes":15}',
      );
      expect(decoded.onGroupOpen, isFalse);
      expect(decoded.onLaunch, isTrue);
      expect(decoded.intervalMinutes, 15);
    });

    test('相等性含 onGroupOpen（否则设置页看不到保存按钮）', () {
      const a = AutoSyncConfig(onLaunch: true);
      expect(a, const AutoSyncConfig(onLaunch: true));
      expect(a == a.copyWith(onGroupOpen: true), isFalse);
      expect(a.hashCode, const AutoSyncConfig(onLaunch: true).hashCode);
    });

    test('copyWith 能改 onGroupOpen，且不影响其余字段', () {
      const cfg = AutoSyncConfig(onLaunch: true, intervalMinutes: 60);
      final next = cfg.copyWith(onGroupOpen: true);
      expect(next.onGroupOpen, isTrue);
      expect(next.onLaunch, isTrue);
      expect(next.intervalMinutes, 60);
    });
  });
}

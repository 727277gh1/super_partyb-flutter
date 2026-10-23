import 'package:test/test.dart';

import 'package:spb_domain/spb_domain.dart';

/// 进入对话时的同步判定 + 冷却闸。
///
/// ## 为什么这些必须能无头测
///
/// 判据是**正确性核心**：判错的方向有两个，都很糟。
/// - 该同步却判成 upToDate → 用户开了功能却看不到任何效果（静默失效）；
/// - 不该同步却判成 stale → 每次点对话都拉一轮（首次可能有几百 MB）。
///
/// 两者都只在真实网络+真实状态库下才暴露，故必须把判据抽成纯函数逐条钉住。
void main() {
  /// 构造一个「已同步 2 个文件、最晚 updated_at 为 08:00」的水位。
  GroupSyncWatermark watermark([String? latest = '2026-10-21T08:00:00Z']) =>
      GroupSyncWatermark(latestUpdatedAt: latest, fileCount: 2);

  group('groupSyncNeed 判定', () {
    test('远端最晚时间晚于本地水位 → stale', () {
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T09:00:00Z',
          local: watermark(),
        ),
        GroupSyncNeed.stale,
      );
    });

    test('远端最晚时间早于本地水位 → upToDate', () {
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T07:00:00Z',
          local: watermark(),
        ),
        GroupSyncNeed.upToDate,
      );
    });

    test('恰好等于水位 → upToDate（那份文件就是抬升水位的那个）', () {
      // 严格大于而非 >=：`>=` 会让「同步完最后一轮」永远判成 stale——
      // 水位正是被那份文件抬上去的。
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T08:00:00Z',
          local: watermark(),
        ),
        GroupSyncNeed.upToDate,
      );
    });

    test('从未同步过这个 group（水位为空）→ stale', () {
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T08:00:00Z',
          local: GroupSyncWatermark.none,
        ),
        GroupSyncNeed.stale,
      );
    });

    test('有记录但都没带 updated_at → unknown（无从比较）', () {
      // ## 为什么不是 stale
      //
      // 说 stale 会让这个 group 每轮都提示、每轮都追不上（下载完成后仍然
      // 没有 updated_at 可抬升水位）——那是一个永不消失的提示条。
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '2026-10-21T08:00:00Z',
          local: watermark(null),
        ),
        GroupSyncNeed.unknown,
      );
    });

    test('远端没有条目 → unknown（不是 upToDate）', () {
      // 语义区别：upToDate 是「比对过了，本地最新」，unknown 是「没东西可比」。
      // 当前用户可见后果相同，但混用会让将来加「本对话没有交付物」空态时无从区分。
      expect(
        groupSyncNeed(remoteLatestUpdatedAt: null, local: watermark()),
        GroupSyncNeed.unknown,
      );
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: '  ',
          local: GroupSyncWatermark.none,
        ),
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
          local: watermark(),
        ),
        GroupSyncNeed.stale,
      );
    });

    test('首尾空白被忽略（偏好表里存过带空格的值）', () {
      expect(
        groupSyncNeed(
          remoteLatestUpdatedAt: ' 2026-10-21T09:00:00Z ',
          local: watermark(),
        ),
        GroupSyncNeed.stale,
      );
    });
  });

  group('groupSyncWatermark：从状态里取本 group 水位', () {
    SyncState stateWith(Map<String, String?> files, {String? cursor}) =>
        SyncState(
          cursor: cursor,
          files: {
            for (final e in files.entries)
              e.key: SyncedFile(size: 1, updatedAt: e.value),
          },
        );

    test('workspace 布局：只取首段等于 groupId 的条目', () {
      // ## 为什么这是本函数最易错的地方
      //
      // 状态表是**跨 group 共享**的（workspace 布局）。若不过滤，别的 group
      // 里的新文件会把水位抬到很高，本 group 就永远判 upToDate——用户看不到
      // 提示，而本地确实缺文件。
      final wm = groupSyncWatermark(
        state: stateWith({
          'g1/a.md': '2026-10-21T08:00:00Z',
          'g1/b.md': '2026-10-21T10:00:00Z',
          'g2/c.md': '2026-10-21T23:00:00Z',
        }),
        stateKey: workspaceStateKey,
        groupId: 'g1',
      );
      expect(wm.fileCount, 2);
      expect(wm.latestUpdatedAt, '2026-10-21T10:00:00Z');
      expect(wm.isEmpty, isFalse);
    });

    test('groupId 是前缀而不是首段时不算（g1 不能命中 g10/x）', () {
      final wm = groupSyncWatermark(
        state: stateWith({'g10/a.md': '2026-10-21T23:00:00Z'}),
        stateKey: workspaceStateKey,
        groupId: 'g1',
      );
      expect(wm.isEmpty, isTrue);
      expect(wm.latestUpdatedAt, isNull);
    });

    test('单 group 布局：状态键就是该 group，全部条目都算', () {
      // ## 为什么必须区分两种布局
      //
      // `syncStateKeyFor` 让单 group 模式用 groupId 作状态键、落盘**无**
      // `{gid}/` 前缀。若一律按「首段 == gid」判定，这里一条都匹配不上，
      // 水位恒空 → 判定永远 stale。
      final wm = groupSyncWatermark(
        state: stateWith({
          'reports/a.md': '2026-10-21T08:00:00Z',
          'reports/b.md': '2026-10-21T10:00:00Z',
        }),
        stateKey: 'g1',
        groupId: 'g1',
      );
      expect(wm.fileCount, 2);
      expect(wm.latestUpdatedAt, '2026-10-21T10:00:00Z');
    });

    test('单 group 布局下状态键与 groupId 不符 → 空', () {
      final wm = groupSyncWatermark(
        state: stateWith({'reports/a.md': '2026-10-21T08:00:00Z'}),
        stateKey: 'g2',
        groupId: 'g1',
      );
      expect(wm.isEmpty, isTrue);
    });

    test('空状态 / 空 groupId → 空', () {
      expect(
        groupSyncWatermark(
          state: SyncState.empty,
          stateKey: workspaceStateKey,
          groupId: 'g1',
        ).isEmpty,
        isTrue,
      );
      expect(
        groupSyncWatermark(
          state: SyncState.empty,
          stateKey: workspaceStateKey,
          groupId: '',
        ).isEmpty,
        isTrue,
      );
    });

    test('首段之后没有斜杠的条目不计（它是 group 根目录）', () {
      final wm = groupSyncWatermark(
        state: stateWith({'g1': '2026-10-21T08:00:00Z'}),
        stateKey: workspaceStateKey,
        groupId: 'g1',
      );
      expect(wm.isEmpty, isTrue);
    });

    test('条目里的 updated_at 为空时不计入最晚值，但仍计入条数', () {
      final wm = groupSyncWatermark(
        state: stateWith({'g1/a.md': null, 'g1/b.md': '2026-10-21T10:00:00Z'}),
        stateKey: workspaceStateKey,
        groupId: 'g1',
      );
      expect(wm.fileCount, 2);
      expect(wm.latestUpdatedAt, '2026-10-21T10:00:00Z');
    });

    test('不看游标（游标跨 group 共享，定向同步不会推进它）', () {
      // 这条钉住「判据已从游标改为水位」——若实现又改回读 cursor，
      // 定向同步后会永远判 stale（游标不动而远端时间总大于它）。
      final wm = groupSyncWatermark(
        state: stateWith({
          'g1/a.md': '2026-10-21T08:00:00Z',
        }, cursor: '2026-10-21T23:00:00Z'),
        stateKey: workspaceStateKey,
        groupId: 'g1',
      );
      expect(
        wm.latestUpdatedAt,
        '2026-10-21T08:00:00Z',
        reason: '水位来自文件记录，不是游标',
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

import 'dart:convert';

import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `HabitTriggerConfig` 一族（time_based / watch 联合视图）测试。
///
/// ## 为什么需要它
///
/// `habit_pattern.dart` 的 `summary` / `toJson` / `isEmpty` 此前零覆盖，而它们是
/// **正确性核心**——摘要直接显示给用户，`toJson` 是提交给服务端的请求体。
///
/// ## 四个必须钉住的语义
///
/// 1. **`summary` 的周几映射**：`weekday` 是 **1=周一 … 7=周日**，与 Go 的
///    `time.Weekday()`（0=周日）**不同**——错一位会把「周一」显示成「周日」。
/// 2. **`isEmpty` 不能写成 `raw.isEmpty`**：客户端手工构造的配置 `raw` 为空，
///    但那不是「未配置」。判据必须是分派后的具体形状。
/// 3. **`toJson` 保留未知键**：服务端 `NormalizeTriggerConfig` 明确保留未知键，
///    客户端编辑时不能把它们吃掉（否则用户的扩展配置会被静默丢弃）。
/// 4. **`weekdays` 复数也能读**（历史数据），但**写出时只写单数** `weekday`。
void main() {
  group('HabitTimeTriggerConfig.summary', () {
    /// ⚠️ weekday 是 1=周一 … 7=周日。
    HabitTimeTriggerConfig timeCfg({
      List<HabitTimeOfDay> times = const [],
      List<int> weekdays = const [],
      int? hour,
      int? minute,
    }) => HabitTimeTriggerConfig(
      times: times,
      weekdays: weekdays,
      hour: hour,
      minute: minute,
    );

    test('无触发时间 → 「未配置触发时间」', () {
      expect(timeCfg().summary, '未配置触发时间');
    });

    test('每天：weekdays 为空', () {
      expect(timeCfg(hour: 9, minute: 0).summary, '每天 09:00');
      expect(timeCfg(hour: 9).summary, '每天 09:00', reason: 'minute 缺省 0');
    });

    test('weekday 映射是 1=周一 … 7=周日（不是 Go 的 0=周日）', () {
      // 错一位会把「周一」显示成「周日」——这条专门钉住映射。
      expect(timeCfg(hour: 9, weekdays: [1]).summary, '每周一 09:00');
      expect(timeCfg(hour: 9, weekdays: [7]).summary, '每周日 09:00');
      expect(timeCfg(hour: 9, weekdays: [1, 3, 5]).summary, '每周一、三、五 09:00');
    });

    test('优先 times[0]，回退顶层 hour/minute', () {
      final withTimes = timeCfg(
        times: const [HabitTimeOfDay(hour: 8, minute: 30)],
        hour: 23, // 影子字段，应被 times[0] 盖过
        minute: 59,
      );
      expect(withTimes.summary, '每天 08:30');

      final onlyShadow = timeCfg(hour: 8, minute: 30);
      expect(onlyShadow.summary, '每天 08:30');
    });

    test('越界的 weekday（0 / 8 / 负数）被过滤；全越界回「每天」', () {
      expect(timeCfg(hour: 9, weekdays: [0, 8, -1]).summary, '每天 09:00');
      expect(timeCfg(hour: 9, weekdays: [1, 99]).summary, '每周一 09:00');
    });

    test('hour 补零到两位', () {
      expect(timeCfg(hour: 9, minute: 5).summary, '每天 09:05');
      expect(timeCfg(hour: 23, minute: 59).summary, '每天 23:59');
    });
  });

  group('HabitTimeTriggerConfig.fromJson', () {
    test('times 数组解析（每项 {hour, minute}）', () {
      final c = HabitTimeTriggerConfig.fromJson(const {
        'times': [
          {'hour': 9, 'minute': 30},
          {'hour': 18, 'minute': 0},
        ],
      });
      expect(c.times, hasLength(2));
      expect(c.times.first.hour, 9);
      expect(c.times.first.minute, 30);
      expect(c.firstHour, 9);
      expect(c.firstMinute, 30);
    });

    test('weekday 单数优先于 weekdays 复数（写入侧已归一）', () {
      final c = HabitTimeTriggerConfig.fromJson(const {
        'weekday': [1],
        'weekdays': [2, 3],
      });
      expect(c.weekdays, [1], reason: '单数优先');
    });

    test('weekdays 复数兜底（历史数据）', () {
      final c = HabitTimeTriggerConfig.fromJson(const {
        'weekdays': [2, 4],
      });
      expect(c.weekdays, [2, 4]);
    });

    test('weekday 是裸 int（非列表）也能读', () {
      expect(HabitTimeTriggerConfig.fromJson(const {'weekday': 3}).weekdays, [
        3,
      ]);
    });

    test('weekday 列表含字符串数字时尽力转换', () {
      final c = HabitTimeTriggerConfig.fromJson(const {
        'weekday': ['1', 2, 'x', null],
      });
      expect(c.weekdays, [1, 2], reason: '非数字项跳过');
    });

    test('times 里非 Map 的元素被跳过（坏行不拖垮）', () {
      final c = HabitTimeTriggerConfig.fromJson(const {
        'times': [
          {'hour': 9},
          'garbage',
          42,
        ],
      });
      expect(c.times, hasLength(1));
    });

    test('空对象 → 全空（isEmpty）', () {
      final c = HabitTimeTriggerConfig.fromJson(const {});
      expect(c.isEmpty, isTrue);
      expect(c.summary, '未配置触发时间');
      expect(c.firstHour, isNull);
    });
  });

  group('HabitTimeTriggerConfig.toJson：只写单数 weekday', () {
    test('round-trip：times / weekdays / hour / minute / mode', () {
      final c = HabitTimeTriggerConfig.fromJson(const {
        'times': [
          {'hour': 9, 'minute': 30},
        ],
        'weekday': [1, 3],
        'hour': 9,
        'minute': 30,
        'mode': 'weekly',
      });
      final out = c.toJson();
      expect(out['times'], [
        {'hour': 9, 'minute': 30},
      ]);
      expect(out['weekday'], [1, 3]);
      expect(out.containsKey('weekdays'), isFalse, reason: '只写单数');
      expect(out['hour'], 9);
      expect(out['minute'], 30);
      expect(out['mode'], 'weekly');
    });

    test('空字段不写入（不给服务端送空键）', () {
      const c = HabitTimeTriggerConfig();
      expect(c.toJson(), isEmpty);
    });

    test('hour 有值但 minute 为 null 时只写 hour', () {
      const c = HabitTimeTriggerConfig(hour: 9);
      final out = c.toJson();
      expect(out['hour'], 9);
      expect(out.containsKey('minute'), isFalse);
    });
  });

  group('HabitWatchTriggerConfig（指数退避盯梢）', () {
    test('summary：无最大间隔扩展时「每 X 检查一次」', () {
      const c = HabitWatchTriggerConfig(initialSeconds: 3600, maxSeconds: 3600);
      expect(c.summary, '每 1 小时 检查一次');
    });

    test('summary：maxSeconds > initial 时带上限', () {
      const c = HabitWatchTriggerConfig(
        initialSeconds: 3600,
        maxSeconds: 86400,
      );
      expect(c.summary, '每 1 小时 起，最长间隔 1 天');
    });

    test('_durationLabel 的秒/分/时/天四级', () {
      expect(
        const HabitWatchTriggerConfig(
          initialSeconds: 30,
          maxSeconds: 30,
        ).summary,
        '每 30 秒 检查一次',
      );
      expect(
        const HabitWatchTriggerConfig(
          initialSeconds: 120,
          maxSeconds: 120,
        ).summary,
        '每 2 分钟 检查一次',
      );
      expect(
        const HabitWatchTriggerConfig(
          initialSeconds: 7200,
          maxSeconds: 7200,
        ).summary,
        '每 2 小时 检查一次',
      );
      expect(
        const HabitWatchTriggerConfig(
          initialSeconds: 172800,
          maxSeconds: 172800,
        ).summary,
        '每 2 天 检查一次',
      );
    });

    test('fromJson：缺字段套用服务端默认值', () {
      final c = HabitWatchTriggerConfig.fromJson(const {});
      expect(c.initialSeconds, HabitWatchTriggerConfig.defaultInitialSeconds);
      expect(c.factor, HabitWatchTriggerConfig.defaultFactor);
      expect(c.maxSeconds, HabitWatchTriggerConfig.defaultMaxSeconds);
      expect(c.maxNoChange, HabitWatchTriggerConfig.defaultMaxNoChange);
      expect(c.expiresAt, isNull);
    });

    test('fromJson：显式 max_no_change=0 必须保留（不是「缺失」）', () {
      // 0 是合法值（第一次无变化就停），与缺失语义不同。
      final c = HabitWatchTriggerConfig.fromJson(const {
        'stop': {'max_no_change': 0},
      });
      expect(c.maxNoChange, 0);
    });

    test('fromJson：负数 max_no_change 表示关闭限制', () {
      final c = HabitWatchTriggerConfig.fromJson(const {
        'stop': {'max_no_change': -1},
      });
      expect(c.maxNoChange, -1);
    });

    test('fromJson：cadence / stop / expires_at 解析', () {
      final c = HabitWatchTriggerConfig.fromJson(const {
        'cadence': {'initial_seconds': 60, 'factor': 1.5, 'max_seconds': 600},
        'stop': {'max_no_change': 5, 'expires_at': '2024-04-01T00:00:00Z'},
      });
      expect(c.initialSeconds, 60);
      expect(c.factor, 1.5);
      expect(c.maxSeconds, 600);
      expect(c.maxNoChange, 5);
      expect(c.expiresAt, '2024-04-01T00:00:00Z');
    });

    test('toJson：cadence / stop 形状（expires_at 有值才写）', () {
      const c = HabitWatchTriggerConfig(
        initialSeconds: 60,
        factor: 2,
        maxSeconds: 600,
        maxNoChange: 5,
      );
      final out = c.toJson();
      expect(out['cadence'], {
        'initial_seconds': 60,
        'factor': 2,
        'max_seconds': 600,
      });
      expect(out['stop'], {'max_no_change': 5});
      expect((out['stop'] as Map).containsKey('expires_at'), isFalse);

      const withExpiry = HabitWatchTriggerConfig(
        expiresAt: '2024-04-01T00:00:00Z',
      );
      expect(
        (withExpiry.toJson()['stop'] as Map)['expires_at'],
        '2024-04-01T00:00:00Z',
      );
    });
  });

  group('HabitTriggerConfig：按 trigger_type 分派', () {
    test('watch 类型（顶层 trigger_type）', () {
      final c = HabitTriggerConfig.fromJson(const {
        'cadence': {'initial_seconds': 60},
      }, triggerTypeRaw: 'watch');
      expect(c.triggerType, HabitTriggerType.watch);
      expect(c.watch, isNotNull);
      expect(c.time, isNull);
    });

    test('cadence 键存在时也判 watch（即使 trigger_type 缺省）', () {
      // `WatchTriggerConfig` 会写入 cadence，故这是可靠的形状判据。
      final c = HabitTriggerConfig.fromJson(const {
        'cadence': {'initial_seconds': 60},
      });
      expect(c.triggerType, HabitTriggerType.watch);
    });

    test('time_based 类型', () {
      final c = HabitTriggerConfig.fromJson(const {
        'hour': 9,
      }, triggerTypeRaw: 'time_based');
      expect(c.triggerType, HabitTriggerType.timeBased);
      expect(c.time, isNotNull);
      expect(c.watch, isNull);
    });

    test('trigger_type 也可嵌在 config 内', () {
      final c = HabitTriggerConfig.fromJson(const {
        'trigger_type': 'watch',
        'cadence': {'initial_seconds': 60},
      });
      expect(c.triggerType, HabitTriggerType.watch);
    });

    test('未知 trigger_type 落到 unknown（不抛）', () {
      final c = HabitTriggerConfig.fromJson(const {'hour': 9});
      expect(c.triggerType, HabitTriggerType.unknown);
      // unknown 走 time 分支（非 watch）。
      expect(c.time, isNotNull);
    });
  });

  group('HabitTriggerConfig.isEmpty：不能用 raw.isEmpty', () {
    test('手工构造的 time 配置不算空（raw 为空但形状非空）', () {
      // 若写成 `raw.isEmpty`，这里会恒为 true，UI 把用户刚配的「每周一 9:00」
      // 显示成「未配置触发条件」。
      const c = HabitTriggerConfig(
        triggerType: HabitTriggerType.timeBased,
        time: HabitTimeTriggerConfig(hour: 9, weekdays: [1]),
      );
      expect(c.raw, isEmpty);
      expect(c.isEmpty, isFalse, reason: '判据必须是分派后的形状，不是 raw');
    });

    test('time 为 null 或空 → isEmpty', () {
      const noTime = HabitTriggerConfig(
        triggerType: HabitTriggerType.timeBased,
      );
      expect(noTime.isEmpty, isTrue);

      const emptyTime = HabitTriggerConfig(
        triggerType: HabitTriggerType.timeBased,
        time: HabitTimeTriggerConfig(),
      );
      expect(emptyTime.isEmpty, isTrue);
    });

    test('watch 类型看 watch 是否为 null', () {
      const noWatch = HabitTriggerConfig(triggerType: HabitTriggerType.watch);
      expect(noWatch.isEmpty, isTrue);

      const withWatch = HabitTriggerConfig(
        triggerType: HabitTriggerType.watch,
        watch: HabitWatchTriggerConfig(),
      );
      expect(withWatch.isEmpty, isFalse, reason: '有默认 watch 配置即非空');
    });

    test('从 JSON 解析的空配置判空', () {
      final c = HabitTriggerConfig.fromJson(const {});
      expect(c.isEmpty, isTrue);
    });
  });

  group('HabitTriggerConfig.summary', () {
    test('time 类型用 time.summary；watch 类型用 watch.summary', () {
      final t = HabitTriggerConfig.fromJson(const {
        'hour': 9,
        'weekday': [1],
      });
      expect(t.summary, '每周一 09:00');

      final w = HabitTriggerConfig.fromJson(const {
        'cadence': {'initial_seconds': 3600, 'max_seconds': 3600},
      }, triggerTypeRaw: 'watch');
      expect(w.summary, '每 1 小时 检查一次');
    });

    test('无配置 → 「未配置触发条件」', () {
      expect(HabitTriggerConfig.fromJson(const {}).summary, '未配置触发条件');
      const noWatch = HabitTriggerConfig(triggerType: HabitTriggerType.watch);
      expect(noWatch.summary, '未配置触发条件');
    });
  });

  group('HabitTriggerConfig.toJson：保留未知键', () {
    test('time 类型：未知键与 time 形状合并', () {
      final c = HabitTriggerConfig.fromJson(const {
        'hour': 9,
        'future_ext': {'x': 1},
      });
      final out = c.toJson();
      expect(out['hour'], 9);
      // 服务端 NormalizeTriggerConfig 保留未知键，客户端不得吃掉。
      expect(out['future_ext'], {'x': 1});
    });

    test('watch 类型：未知键与 watch 形状合并', () {
      final c = HabitTriggerConfig.fromJson(const {
        'cadence': {'initial_seconds': 60},
        'future_ext': 'keep-me',
      }, triggerTypeRaw: 'watch');
      final out = c.toJson();
      expect(out['cadence'], isA<Map<dynamic, dynamic>>());
      expect(out['future_ext'], 'keep-me');
    });

    test('手工构造（无 raw）时也能产出合法形状', () {
      const c = HabitTriggerConfig(
        triggerType: HabitTriggerType.timeBased,
        time: HabitTimeTriggerConfig(hour: 9),
      );
      expect(c.toJson()['hour'], 9);
    });
  });

  group('HabitTriggerConfig.fromJsonString', () {
    test('合法 JSON 字符串解析', () {
      final c = HabitTriggerConfig.fromJsonString(
        jsonEncode({
          'hour': 9,
          'weekday': [1],
        }),
        triggerTypeRaw: 'time_based',
      );
      expect(c.summary, '每周一 09:00');
    });

    test('null / 空串 / 纯空白 → 空配置（不抛）', () {
      expect(HabitTriggerConfig.fromJsonString(null).isEmpty, isTrue);
      expect(HabitTriggerConfig.fromJsonString('').isEmpty, isTrue);
      expect(HabitTriggerConfig.fromJsonString('   ').isEmpty, isTrue);
    });

    test('非法 JSON 按「无配置」处理（不抛）', () {
      // 服务端也可能存了非法 JSON（NormalizeTriggerConfig 原样返回并报错）。
      expect(HabitTriggerConfig.fromJsonString('{not json').isEmpty, isTrue);
    });

    test('合法 JSON 但不是对象（数组）→ 空配置', () {
      expect(HabitTriggerConfig.fromJsonString('[1,2,3]').isEmpty, isTrue);
    });
  });

  group('HabitTimeOfDay', () {
    test('label 补零；fromJson / toJson round-trip', () {
      const t = HabitTimeOfDay(hour: 9, minute: 5);
      expect(t.label, '09:05');
      expect(t.toJson(), {'hour': 9, 'minute': 5});

      final back = HabitTimeOfDay.fromJson(const {'hour': 9, 'minute': 5});
      expect(back.hour, 9);
      expect(back.minute, 5);
    });

    test('缺字段回落 0', () {
      final t = HabitTimeOfDay.fromJson(const {});
      expect(t.hour, 0);
      expect(t.minute, 0);
      expect(t.label, '00:00');
    });
  });

  group('枚举 from：未知 / 空 / null 落到 unknown', () {
    test('HabitTriggerType', () {
      expect(HabitTriggerType.from('watch'), HabitTriggerType.watch);
      expect(HabitTriggerType.from('bogus'), HabitTriggerType.unknown);
      expect(HabitTriggerType.from(null), HabitTriggerType.unknown);
      expect(HabitTriggerType.from(''), HabitTriggerType.unknown);
    });

    test('HabitAcceptanceLevel', () {
      expect(
        HabitAcceptanceLevel.from('auto_run'),
        HabitAcceptanceLevel.autoRun,
      );
      expect(HabitAcceptanceLevel.from('bogus'), HabitAcceptanceLevel.unknown);
    });

    test('HabitPatternStatus', () {
      expect(HabitPatternStatus.from('active'), HabitPatternStatus.active);
      expect(HabitPatternStatus.from('bogus'), HabitPatternStatus.unknown);
    });

    test('HabitSourceType', () {
      expect(HabitSourceType.from('manual'), HabitSourceType.manual);
      expect(HabitSourceType.from('bogus'), HabitSourceType.unknown);
    });

    test('label 是中文展示名', () {
      expect(HabitTriggerType.watch.label, '盯梢');
      expect(HabitAcceptanceLevel.confirmRequired.label, '需确认');
      expect(HabitPatternStatus.archived.label, '已归档');
      expect(HabitSourceType.learned.label, '自动学习');
    });
  });
}

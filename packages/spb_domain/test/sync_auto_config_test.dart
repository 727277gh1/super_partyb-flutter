import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// `AutoSyncConfig` 的序列化与档位钳制。
///
/// ## 为什么这些用例值得存在
///
/// 这个类型的两个判据都会**静默**出错：
///
/// 1. 损坏值退回「全关」还是「全开」——退回全开会在用户毫不知情的情况下
///    持续拉取（首次全量生产实测 4.7 GB）；
/// 2. 非法间隔钳到哪一档——钳到 0 会让「自动同步」看起来好好的却不工作。
///
/// 两者都没有任何界面能暴露，故必须逐条钉住。
void main() {
  group('AutoSyncConfig 基本语义', () {
    test('默认是全关', () {
      const c = AutoSyncConfig.disabled;
      expect(c.onLaunch, isFalse);
      expect(c.intervalMinutes, 0);
      expect(c.isPeriodic, isFalse);
      expect(c.isEnabled, isFalse);
    });

    test('只开启动同步也算启用（不需要周期）', () {
      const c = AutoSyncConfig(onLaunch: true);
      expect(c.isPeriodic, isFalse);
      expect(c.isEnabled, isTrue);
    });

    test('只开周期同步也算启用（不需要启动同步）', () {
      const c = AutoSyncConfig(intervalMinutes: 30);
      expect(c.onLaunch, isFalse);
      expect(c.isPeriodic, isTrue);
      expect(c.isEnabled, isTrue);
    });

    test('allowedIntervals 含 0（「关闭」是下拉的合法选项）', () {
      expect(AutoSyncConfig.allowedIntervals, contains(0));
      expect(AutoSyncConfig.allowedIntervals, isNotEmpty);
    });

    test('copyWith 只改指定字段', () {
      const c = AutoSyncConfig(onLaunch: true, intervalMinutes: 30);
      expect(
        c.copyWith(onLaunch: false),
        const AutoSyncConfig(intervalMinutes: 30),
      );
      expect(
        c.copyWith(intervalMinutes: 60),
        const AutoSyncConfig(onLaunch: true, intervalMinutes: 60),
      );
      // 无参 copyWith 等于原值。
      expect(c.copyWith(), c);
    });

    test('相等性与 hashCode 都参与两个字段', () {
      const a = AutoSyncConfig(onLaunch: true, intervalMinutes: 30);
      const b = AutoSyncConfig(onLaunch: true, intervalMinutes: 30);
      const c = AutoSyncConfig(onLaunch: false, intervalMinutes: 30);
      const d = AutoSyncConfig(onLaunch: true, intervalMinutes: 60);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(d));
    });

    test('toString 含两个字段（日志可读）', () {
      const c = AutoSyncConfig(onLaunch: true, intervalMinutes: 15);
      expect(c.toString(), contains('onLaunch: true'));
      expect(c.toString(), contains('intervalMinutes: 15'));
    });
  });

  group('encode / decode 往返', () {
    test('往返保持原值', () {
      const c = AutoSyncConfig(onLaunch: true, intervalMinutes: 60);
      expect(AutoSyncConfig.decode(c.encode()), c);
    });

    test('全关也能往返（不能因为「默认值」就退化成 null）', () {
      const c = AutoSyncConfig.disabled;
      expect(AutoSyncConfig.decode(c.encode()), c);
    });

    test('null / 空串 / 空白 → 全关', () {
      expect(AutoSyncConfig.decode(null), AutoSyncConfig.disabled);
      expect(AutoSyncConfig.decode(''), AutoSyncConfig.disabled);
      expect(AutoSyncConfig.decode('   '), AutoSyncConfig.disabled);
    });

    test('损坏的 JSON → 全关（不是全开）', () {
      // 这条是本文件最重要的断言：退回「全开」会静默替用户拉 4.7 GB。
      expect(AutoSyncConfig.decode('{not json'), AutoSyncConfig.disabled);
      expect(AutoSyncConfig.decode('[]'), AutoSyncConfig.disabled);
      expect(AutoSyncConfig.decode('"x"'), AutoSyncConfig.disabled);
      expect(AutoSyncConfig.decode('42'), AutoSyncConfig.disabled);
    });

    test('字段类型不对时各自回退，不整体丢弃', () {
      // on_launch 不是 bool → false；interval 仍是合法值 → 保留。
      final c = AutoSyncConfig.decode(
        '{"on_launch":"yes","interval_minutes":30}',
      );
      expect(c.onLaunch, isFalse);
      expect(c.intervalMinutes, 30);
    });

    test('interval 是字符串数字也能解析（偏好表可能存成文本）', () {
      expect(
        AutoSyncConfig.decode('{"on_launch":false,"interval_minutes":"60"}')
            .intervalMinutes,
        60,
      );
    });

    test('缺失字段按默认值（on_launch=false / interval=0）', () {
      expect(AutoSyncConfig.decode('{}'), AutoSyncConfig.disabled);
    });
  });

  group('间隔档位钳制', () {
    test('合法档位原样保留', () {
      for (final v in AutoSyncConfig.allowedIntervals) {
        expect(
          AutoSyncConfig.decode('{"interval_minutes":$v}').intervalMinutes,
          v,
          reason: '$v 是合法档位',
        );
      }
    });

    test('负数与 0 都归到 0（不周期）', () {
      expect(
        AutoSyncConfig.decode('{"interval_minutes":-5}').intervalMinutes,
        0,
      );
      expect(
        AutoSyncConfig.decode('{"interval_minutes":0}').intervalMinutes,
        0,
      );
    });

    test('非数字归到 0', () {
      expect(
        AutoSyncConfig.decode('{"interval_minutes":"abc"}').intervalMinutes,
        0,
      );
    });

    test('非法档位就近钳制，不退化成 0', () {
      // ## 为什么这条重要
      //
      // 若钳到 0，「自动同步」会在档位集合调整后静默失效——用户看到开关
      // 还开着，却再也不同步。就近钳制至少保住「仍在自动同步」这个意图。
      expect(
        AutoSyncConfig.decode('{"interval_minutes":20}').intervalMinutes,
        15,
      );
      expect(
        AutoSyncConfig.decode('{"interval_minutes":45}').intervalMinutes,
        30,
      );
      expect(
        AutoSyncConfig.decode('{"interval_minutes":100}').intervalMinutes,
        60,
      );
      expect(
        AutoSyncConfig.decode('{"interval_minutes":1000}').intervalMinutes,
        180,
      );
    });

    test('等距时取较小档位', () {
      // 整数输入下唯一的**精确等距**是 45（30 与 60 的中点）：
      // 距两者都是 15 → 取较小档 30。
      expect(
        AutoSyncConfig.decode('{"interval_minutes":45}').intervalMinutes,
        30,
      );
      // 其余是「接近但不相等」的边界，逐条钉住判定方向：
      // 22 距 15 为 7、距 30 为 8 → 15；23 反之 → 30。
      expect(
        AutoSyncConfig.decode('{"interval_minutes":22}').intervalMinutes,
        15,
      );
      expect(
        AutoSyncConfig.decode('{"interval_minutes":23}').intervalMinutes,
        30,
      );
      // 7 距 0 为 7、距 15 为 8 → 0；8 反之 → 15。
      expect(
        AutoSyncConfig.decode('{"interval_minutes":7}').intervalMinutes,
        0,
      );
      expect(
        AutoSyncConfig.decode('{"interval_minutes":8}').intervalMinutes,
        15,
      );
    });

    test('钳制后的值仍是可往返的合法档位', () {
      final c = AutoSyncConfig.decode(
        '{"on_launch":true,"interval_minutes":999}',
      );
      expect(c.intervalMinutes, 180);
      expect(AutoSyncConfig.allowedIntervals, contains(c.intervalMinutes));
      expect(AutoSyncConfig.decode(c.encode()), c);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';

/// 时间线定位键注册表（`RowLocateRegistry`）测试。
///
/// ## 这个测试防的是什么
///
/// `GlobalKey` 的注册与回收是**互相拉扯**的一对约束（issue #39）：
///
/// - 注册少了：搜索命中后 `_scrollToItem` 找不到键 → 退化成「请向上滚动」，
///   而目标明明在屏幕上；
/// - 回收少了：跨 group 切换持续累积，旧键对应的 Element 无法回收；
/// - 回收多了：**仍在渲染**的行的键被删 → 下一帧 `putIfAbsent` 生成**新**键，
///   `KeyedSubtree` 卸载重挂，滚动位置丢失。
///
/// 三条都不会抛异常，只会「表现不太对」，故逐条锁定。
void main() {
  group('keyFor 注册', () {
    test('同一行多次取 → 同一 GlobalKey（跨重建复用）', () {
      final reg = RowLocateRegistry();
      final a = reg.keyFor(['m1']);
      final b = reg.keyFor(['m1']);
      expect(identical(a, b), isTrue, reason: '复用键是 KeyedSubtree 的前提');
    });

    test('不同行 → 不同 GlobalKey', () {
      final reg = RowLocateRegistry();
      expect(identical(reg.keyFor(['m1']), reg.keyFor(['m2'])), isFalse);
    });

    test('批量卡的每个成员都映射到同一个键', () {
      final reg = RowLocateRegistry();
      final key = reg.keyFor(['f1', 'f2', 'f3']);
      expect(identical(reg['f1'], key), isTrue);
      expect(identical(reg['f2'], key), isTrue);
      expect(identical(reg['f3'], key), isTrue);
      // 搜到批内第 3 个文件时必须能定位（只注册首成员会退化）。
      expect(reg['f3'], isNotNull);
    });

    test('登记后按 id 可查，未登记为 null', () {
      final reg = RowLocateRegistry();
      reg.keyFor(['m1']);
      expect(reg['m1'], isNotNull);
      expect(reg['nope'], isNull);
    });
  });

  group('recycle 回收', () {
    test('回收不在 liveIds 里的键', () {
      final reg = RowLocateRegistry();
      reg.keyFor(['m1']);
      reg.keyFor(['m2']);
      expect(reg.length, 2);

      reg.recycle({'m1'});

      expect(reg['m1'], isNotNull, reason: '仍在线上的行不能丢键');
      expect(reg['m2'], isNull, reason: '已裁剪的行必须回收');
      expect(reg.length, 1);
    });

    test('保留的行拿到的是**同一个** GlobalKey（未清空重建）', () {
      final reg = RowLocateRegistry();
      final before = reg.keyFor(['m1']);
      reg.keyFor(['m2']);

      reg.recycle({'m1'});

      // 若实现是「清空后重建」，这里会拿到新实例 → KeyedSubtree 重挂。
      expect(identical(reg.keyFor(['m1']), before), isTrue);
    });

    test('批量卡内某个成员被裁掉时，其余成员仍共享同一个键', () {
      final reg = RowLocateRegistry();
      final key = reg.keyFor(['f1', 'f2', 'f3']);

      // 批内只剩 f2/f3（f1 被裁）——按「活着的 id」回收。
      reg.recycle({'f2', 'f3'});

      expect(reg['f1'], isNull);
      expect(identical(reg['f2'], key), isTrue);
      expect(identical(reg['f3'], key), isTrue);
    });

    test('空 liveIds → 全部回收（切到空对话）', () {
      final reg = RowLocateRegistry();
      reg.keyFor(['m1']);
      reg.keyFor(['m2']);

      reg.recycle(const {});

      expect(reg.length, 0);
    });

    test('空注册表上回收是安全的 no-op', () {
      final reg = RowLocateRegistry();
      reg.recycle({'m1'});
      expect(reg.length, 0);
    });

    test('liveIds 含未登记的 id 不报错（只按已登记项过滤）', () {
      final reg = RowLocateRegistry();
      reg.keyFor(['m1']);

      reg.recycle({'m1', 'never_registered'});

      expect(reg.length, 1);
      expect(reg['m1'], isNotNull);
    });
  });

  group('组合：注册-回收-再注册', () {
    test('回收后重新出现的行拿到**新**键（旧键已无 Element）', () {
      final reg = RowLocateRegistry();
      final old = reg.keyFor(['m1']);
      reg.recycle(const {});

      final fresh = reg.keyFor(['m1']);

      expect(identical(fresh, old), isFalse);
    });

    test('反复 recycle 不改变仍在线上行的键（长会话滚动）', () {
      final reg = RowLocateRegistry();
      final key = reg.keyFor(['m1', 'm2']);
      for (var i = 0; i < 5; i++) {
        reg.recycle({'m1', 'm2'});
      }
      expect(identical(reg.keyFor(['m1']), key), isTrue);
      expect(reg.length, 2);
    });
  });
}

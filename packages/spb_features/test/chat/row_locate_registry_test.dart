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
///
/// ## 第四类：同一 `GlobalKey` 被多行共用（一个真实缺陷）
///
/// 此前 `keyFor` 把批量卡的**每个成员**都写成同一个键实例。于是「同一段
/// 文件被拆成多行」时（缓冲区裁剪 / 翻页拼接都会），多行拿到**同一个**
/// `GlobalKey`，Flutter 抛 `Multiple widgets used the same GlobalKey`，
/// 后出现的那几行**渲染为空白**——用户看到的就是「滚动时内容丢了，
/// 再滚又出现了」。
///
/// 它不抛到页面的 `catch` 里、也不改归约结果，故只能在这里按「键的实例
/// 身份」逐条钉住（见 `同一段文件被拆成多行` 组）。
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

    test('批量卡内某个**非首**成员被裁掉时，其余成员仍解析到同一个键', () {
      final reg = RowLocateRegistry();
      final key = reg.keyFor(['f1', 'f2', 'f3']);

      // 批内只剩 f1/f2（f3 被裁，首成员 f1 仍在）——按「活着的 id」回收。
      reg.recycle({'f1', 'f2'});

      expect(reg['f3'], isNull);
      expect(identical(reg['f1'], key), isTrue);
      expect(identical(reg['f2'], key), isTrue);
    });

    test('首成员（行主键）被裁掉时，该行的键随之失效', () {
      final reg = RowLocateRegistry();
      final oldKey = reg.keyFor(['f1', 'f2', 'f3']);

      // 裁剪吃掉 f1，批仍在（首成员变成 f2）。
      reg.recycle({'f2', 'f3'});

      // 旧键属于「batch:f1」这个身份，而下一帧的 ValueKey 也会变成
      // `batch:f2`（`conversation_page` 的 `batch:${files.first.id}`）——
      // 两个身份本就不同，不能沿用旧键。
      expect(reg['f1'], isNull);
      final fresh = reg.keyFor(['f2', 'f3']);
      expect(identical(fresh, oldKey), isFalse);
      // 但批内成员彼此仍指向同一个键（它们在同一张卡里）。
      expect(identical(reg['f2'], reg['f3']), isTrue);
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
      // 行数只数主键：m2 是 m1 的别名，不是一行。
      expect(reg.length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // 真实缺陷回归：同一段文件被拆成多行
  //
  // 场景来自生产：缓冲上限 2000 条（`ChatStreamController.maxBufferEvents`）
  // 从头部丢最旧事件，边界可能落在批量卡中间。7 个同秒文件剩 4 个 → 不足
  // `FILE_BATCH_MIN_COUNT`（5）→ 退回 4 个 `SingleItemRow`。
  //
  // 若成员共享键实例，这 4 行会撞同一个 `GlobalKey`。
  // -------------------------------------------------------------------------
  group('同一段文件被拆成多行（缺陷回归）', () {
    test('批量卡拆成 4 个独立行时，各行拿到**不同**的 GlobalKey', () {
      final reg = RowLocateRegistry();
      // 拆前：一张批量卡，7 个成员共用一个定位点。
      final batchKey = reg.keyFor(['f0', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6']);

      // 拆后：f3..f6 各自成行（f0..f2 已被裁剪，故不在 live 集合里）。
      final live = {'f3', 'f4', 'f5', 'f6'};
      reg.recycle(live);

      final keys = [
        for (final id in ['f3', 'f4', 'f5', 'f6']) reg.keyFor([id]),
      ];

      // 每一行都必须是自己的键（撞键会让后出现的那几行渲染为空白）。
      expect(keys.toSet(), hasLength(4), reason: '4 行必须拿到 4 个不同的 GlobalKey');
      // 且不能复用到已回收的批量卡键上。
      for (final k in keys) {
        expect(identical(k, batchKey), isFalse);
      }
    });

    test('拆散后重组成批量卡：新卡拿到**新**键，不与落单行撞', () {
      final reg = RowLocateRegistry();
      // 落单状态：4 行各自成键。
      final singles = [
        for (final id in ['f3', 'f4', 'f5', 'f6']) reg.keyFor([id]),
      ];

      // 翻页补上更早那一页 → 同 turn 同秒合并回批量卡（首成员 f0）。
      final live = {'f0', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6'};
      reg.recycle(live);
      final merged = reg.keyFor(['f0', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6']);

      expect(
        singles.any((k) => identical(k, merged)),
        isFalse,
        reason: '合并后的批量卡不能沿用落单行的键（那是另一个 widget）',
      );
      // 批内任一成员仍可定位到这张卡。
      expect(identical(reg['f5'], merged), isTrue);
    });

    test('别名在它的主键被回收后失效（不会悬空指向旧键）', () {
      final reg = RowLocateRegistry();
      final batchKey = reg.keyFor(['f0', 'f1', 'f2', 'f3', 'f4']);

      // 整张卡被裁掉（全部成员都不在时间线上）。
      reg.recycle(const {});

      expect(reg['f0'], isNull);
      expect(reg['f3'], isNull, reason: '别名必须随主键一起失效');
      expect(reg.length, 0);

      // 成员以独立行重新出现时，不能拿到那个已回收的键。
      final fresh = reg.keyFor(['f3']);
      expect(identical(fresh, batchKey), isFalse);
    });

    test('别名不增加行数（7 成员批量卡只算 1 行）', () {
      final reg = RowLocateRegistry();
      reg.keyFor(['f0', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6']);
      expect(reg.length, 1);
    });
  });
}

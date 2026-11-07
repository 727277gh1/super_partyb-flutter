import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

void main() {
  group('GroupTitleCache（docs/memory-audit.md G3）', () {
    test('remember / contains / titleOf 往返（取值语义与裸 Map 一致）', () {
      final c = GroupTitleCache(capacity: 4);
      expect(c.contains('g1'), isFalse);
      expect(c.titleOf('g1'), isNull, reason: 'miss 返回 null（展示「未知对话」）');

      c.remember('g1', '对话一');
      expect(c.contains('g1'), isTrue);
      expect(c.titleOf('g1'), '对话一');
      expect(c.length, 1);
    });

    test('重复写入同一 key：刷新值、不增长、不触发淘汰', () {
      final c = GroupTitleCache(capacity: 2);
      c.remember('g1', '旧名');
      c.remember('g1', '新名');
      c.remember('g1', '新名');

      expect(c.length, 1, reason: '重复写入不增长容量');
      expect(c.titleOf('g1'), '新名');
    });

    test('容量淘汰：最旧写入的 key 被淘汰 → titleOf 返回 null（下次重新拉取）', () {
      final c = GroupTitleCache(capacity: 2);
      c.remember('g_old', '最旧');
      c.remember('g_mid', '中间');
      c.remember('g_new', '最新');

      expect(c.length, 2, reason: '封顶不增长');
      expect(c.titleOf('g_old'), isNull, reason: '淘汰只导致下次预取重新拉取标题，无行为风险');
      expect(c.titleOf('g_mid'), '中间');
      expect(c.titleOf('g_new'), '最新');
    });

    test('重复写入刷新值但不移动次序：最旧写入者仍先被淘汰', () {
      // LinkedHashMap 语义：重复赋值只改值、不移动插入序。生产路径里
      // remember 只在 contains miss 后调用一次（putIfAbsent 式预取），
      // 重复写入不会发生——这条用例只是把语义钉住，防止将来有人误以为
      // 「刷新 = 最近使用」。
      final c = GroupTitleCache(capacity: 2);
      c.remember('g_old', '旧');
      c.remember('g_mid', '中');
      c.remember('g_old', '旧-新');
      c.remember('g_new', '新');

      // 淘汰的是「最旧写入」的 g_old（尽管它刚被刷新过）。
      expect(c.titleOf('g_old'), isNull);
      expect(c.titleOf('g_mid'), '中');
      expect(c.titleOf('g_new'), '新');
    });

    test('clear 全清', () {
      final c = GroupTitleCache(capacity: 4);
      c.remember('g1', '一');
      c.clear();
      expect(c.length, 0);
      expect(c.contains('g1'), isFalse);
    });
  });
}

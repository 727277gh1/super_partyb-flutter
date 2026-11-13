import 'package:test/test.dart';

import 'package:spb_domain/spb_domain.dart';

/// `FeedbackRequestItem.isExpired` 的单元测试。
///
/// ## 为什么这个判据值得独立测试
///
/// 它是「卡片是否还能作答」的唯一客户端依据。写错方向的两个后果都很糟：
///
///   - 太宽松（永远 false）→ 用户点一张早已过期的卡得到 404，「点了没反应」；
///   - 太严格（ttl==null 也判过期）→ 所有卡片一次性变灰，功能直接不可用。
///
/// 而这两个方向在 widget 测试里都不容易覆盖全（那里要造控制器 + 事件流），
/// 故判据本身在纯逻辑层逐条钉住。
void main() {
  final createdAt = DateTime.utc(2026, 10, 21, 10, 0, 0);

  FeedbackRequestItem item({
    String token = 'evt_fb',
    bool resolved = false,
    DateTime? at,
  }) => FeedbackRequestItem(
    id: 'evt_fb',
    createdAt: at ?? createdAt,
    turnId: 'turn_1',
    token: token,
    question: '这条消息我归到了《团队周报》，准确吗？',
    options: const ['准确', '不准确'],
    resolved: resolved,
  );

  group('FeedbackRequestItem.isExpired', () {
    test('超过 TTL 判为已过期', () {
      final it = item();

      expect(
        it.isExpired(
          ttl: const Duration(hours: 1),
          now: createdAt.add(const Duration(hours: 2)),
        ),
        isTrue,
      );
    });

    test('未超过 TTL 不算过期', () {
      final it = item();

      expect(
        it.isExpired(
          ttl: const Duration(hours: 24),
          now: createdAt.add(const Duration(hours: 2)),
        ),
        isFalse,
      );
    });

    test('恰好等于 TTL 不算过期（边界取「超过」而非「达到」）', () {
      // 与服务端 expires_at 的判定同向：SQL 用 `expires_at > CURRENT_TIMESTAMP`
      // 表示仍有效，即「恰好到期」仍可作答。
      final it = item();

      expect(
        it.isExpired(
          ttl: const Duration(hours: 1),
          now: createdAt.add(const Duration(hours: 1)),
        ),
        isFalse,
      );
    });

    test('ttl 为 null（服务端未下发）时恒为 false', () {
      // 这是反方向的关键用例：把「未下发」当成「已过期」会让所有卡片一次性
      // 变灰——旧版后端 + 新版客户端就是这个组合。
      final it = item();

      expect(
        it.isExpired(ttl: null, now: createdAt.add(const Duration(days: 30))),
        isFalse,
      );
    });

    test('已作答的卡不再判过期（已反馈优先于已失效）', () {
      // 语义上两者互斥且 resolved 更强：用户答过了就不该被说「已失效」。
      final it = item(resolved: true);

      expect(
        it.isExpired(
          ttl: const Duration(hours: 1),
          now: createdAt.add(const Duration(days: 30)),
        ),
        isFalse,
      );
    });

    test('createdAt 在未来（时钟偏差）时不判过期', () {
      // 客户端时钟比服务端慢时，事件 createdAt 可能「在未来」。
      // 此时 difference 为负，自然小于 TTL，不会误判——但要有用例钉住，
      // 避免将来有人改成 `difference(...).abs()`。
      final it = item(at: createdAt.add(const Duration(hours: 1)));

      expect(
        it.isExpired(ttl: const Duration(minutes: 10), now: createdAt),
        isFalse,
      );
    });
  });

  group('FeedbackRequestItem.canResolve', () {
    test('有 token 且未作答时可提交', () {
      expect(item().canResolve, isTrue);
    });

    test('缺 token 时不可提交（服务端按 token 直查，必然失败）', () {
      expect(item(token: '').canResolve, isFalse);
    });

    test('已作答时不可提交', () {
      expect(item(resolved: true).canResolve, isFalse);
    });

    test('canResolve 不含有效期判定（调用方需另行调 isExpired）', () {
      // 这是有意的分层：canResolve 拿不到 TTL。若将来有人把 TTL 折进来，
      // 会需要给 getter 加参数、改所有调用点——那是一次接口变更，不是
      // 「顺手修个 bug」。
      final it = item();

      expect(
        it.isExpired(
          ttl: const Duration(hours: 1),
          now: createdAt.add(const Duration(hours: 2)),
        ),
        isTrue,
      );
      expect(it.canResolve, isTrue, reason: 'canResolve 只看 token 与 resolved');
    });
  });
}

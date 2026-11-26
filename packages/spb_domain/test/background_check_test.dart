import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

void main() {
  BackgroundCheckResult result({
    BackgroundCheckOutcome outcome = BackgroundCheckOutcome.ok,
    BackgroundCheckSkip? skip,
    BackgroundCheckFailure? failure,
    int? unread,
    int? fetched,
    int? shown,
    String? error,
  }) => BackgroundCheckResult(
    outcome: outcome,
    at: DateTime.utc(2026, 11, 24, 3, 5),
    skip: skip,
    failure: failure,
    unread: unread,
    fetched: fetched,
    shown: shown,
    error: error,
  );

  group('后台检查读数文案', () {
    test('成功给出抓取与弹出条数（用户念得出来）', () {
      expect(
        describeBackgroundCheckResult(result(unread: 2, fetched: 5, shown: 1)),
        '成功（抓取 5 条，弹出 1 条）',
      );
    });

    test('成功但缺计数时不编数字', () {
      expect(describeBackgroundCheckResult(result()), '成功');
    });

    test('每种跳过原因各自可辨（处置方向不同，不能合成一句）', () {
      final texts = {
        for (final skip in BackgroundCheckSkip.values)
          skip: describeBackgroundCheckResult(
            result(outcome: BackgroundCheckOutcome.skipped, skip: skip),
          ),
      };
      expect(
        texts.values.toSet(),
        hasLength(BackgroundCheckSkip.values.length),
      );
      expect(texts[BackgroundCheckSkip.foreground], contains('前台'));
      expect(texts[BackgroundCheckSkip.noPermission], contains('权限'));
      expect(texts[BackgroundCheckSkip.loggedOut], contains('登录'));
      expect(texts[BackgroundCheckSkip.sessionChanged], contains('账号'));
      expect(texts[BackgroundCheckSkip.interrupted], contains('中断'));
    });

    test('认证失败与请求失败分开（前者要重新登录，后者等下一轮）', () {
      expect(
        describeBackgroundCheckResult(
          result(
            outcome: BackgroundCheckOutcome.failed,
            failure: BackgroundCheckFailure.auth,
          ),
        ),
        contains('重新登录'),
      );
      expect(
        describeBackgroundCheckResult(
          result(
            outcome: BackgroundCheckOutcome.failed,
            failure: BackgroundCheckFailure.request,
          ),
        ),
        '请求失败',
      );
    });

    test('错误摘要单行化并截断（副标题不能被它撑爆）', () {
      final text = describeBackgroundCheckResult(
        result(
          outcome: BackgroundCheckOutcome.failed,
          failure: BackgroundCheckFailure.request,
          error: 'DioException\n  connection   timeout ${'x' * 200}',
        ),
        maxErrorChars: 20,
      );
      expect(text, isNot(contains('\n')));
      expect(text, startsWith('请求失败：DioException'));
      expect(text.endsWith('…'), isTrue);
      expect(text.length, lessThan(60));
    });

    test('空白错误串不拼出「：」这种半句', () {
      expect(
        describeBackgroundCheckResult(
          result(
            outcome: BackgroundCheckOutcome.failed,
            failure: BackgroundCheckFailure.request,
            error: '   ',
          ),
        ),
        '请求失败',
      );
    });
  });
}

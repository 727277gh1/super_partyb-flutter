import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// `spb_core` 错误类型的契约测试。
///
/// ## 这个测试防的是什么
///
/// `errors.dart` 是一个 **sealed class 家族**，它的价值全在「调用方能否在编译期
/// 穷举分支」以及「每个子类携带的语义是否被正确设置」。这些语义**没有类型系统
/// 之外的强制力**——`retryable` 可以传错、`statusCode` 可以漏传、`isUnauthorized`
/// 的边界可以写反，编译器都不会拦。而它们的后果是**行为级的**：
///
///   - `NetworkError.retryable` 错成 false → SSE 断线不再重连，用户看到「卡死」；
///   - `AuthError.statusCode` 漏传 → UI 判不出「该重新登录」，只显示「HTTP 401」；
///   - `HttpError.isRateLimited` 写错 → 429 不退避，直接把服务端打得更狠。
///
/// 故这里逐条钉住这些语义，尤其是**边界**（哪些状态码**不**命中某个谓词）。
///
/// ## ⚠️ 一个与任务描述不符的事实
///
/// 任务描述要求覆盖「状态码映射（401 → AuthError、其余 4xx/5xx → HttpError）」。
/// **这个映射不在 `spb_core`**，而在 `packages/spb_api/lib/src/auth_interceptor.dart`
/// 的 `mapDioError` / `_normalizeAuthError`（依赖 dio 的 `DioExceptionType`，
/// 是传输层职责）。
///
/// `spb_core` 里只有**谓词**（`isUnauthorized` / `isForbidden` / …），没有
/// 「状态码 → 抛哪个类型」的工厂函数。故这里测的是**谓词的边界**，而不是一个
/// 不存在的映射函数；去 `spb_core` 里凭空加一个映射函数属于超范围重构。
void main() {
  group('SpbError 基类', () {
    test('所有子类都是 SpbError（sealed 家族的封闭性）', () {
      // sealed class 的意义就是「编译器知道全部子类」。
      //
      // 这里用 `List<Object>` 而不是 `List<SpbError>`：若声明成后者，
      // `e is SpbError` 会被静态判定为恒真（分析器报 unnecessary_type_check），
      // 而本用例正是要**运行时**验证这个继承关系，故必须让类型检查有意义。
      // 任何子类被误改成不继承 SpbError 都会让这里挂掉。
      final all = <Object>[
        const NetworkError('a'),
        const HttpError(500, 'b'),
        const ParseError('c'),
        const AuthError('d'),
        const StorageError('e'),
        const PlatformError('f'),
        const ValidationError('g'),
      ];

      expect(all, hasLength(7));
      expect(all.every((e) => e is SpbError), isTrue);
      // 同时确认它们都是 Exception（能被 `catch (e)` 接到）。
      expect(all.every((e) => e is Exception), isTrue);
    });

    test('toString 是「类型: 消息」，不是默认的 Instance of …', () {
      // 默认的 `Instance of 'NetworkError'` 不含消息，日志里等于没信息。
      // 这是最容易被「重构成默认实现」而无人察觉的一处。
      expect(const NetworkError('连接超时').toString(), 'NetworkError: 连接超时');
      expect(
        const HttpError(500, 'HTTP 500').toString(),
        'HttpError: HTTP 500',
      );
      expect(const ParseError('坏 JSON').toString(), 'ParseError: 坏 JSON');
      expect(const AuthError('过期').toString(), 'AuthError: 过期');
      expect(const StorageError('磁盘满').toString(), 'StorageError: 磁盘满');
      expect(const PlatformError('无托盘').toString(), 'PlatformError: 无托盘');
      expect(const ValidationError('空输入').toString(), 'ValidationError: 空输入');
    });

    test('cause / stackTrace 被原样保留（不吞原始异常）', () {
      // 吞掉 cause 会让「为什么失败」不可追溯：上层只能看到「网络请求失败」，
      // 看不到底层的 SocketException。
      final cause = StateError('底层原因');
      final st = StackTrace.current;
      final e = NetworkError('包装后', cause: cause, stackTrace: st);

      expect(e.cause, same(cause));
      expect(e.stackTrace, same(st));
      // 默认值是可空 null，不是某种占位对象。
      expect(const NetworkError('x').cause, isNull);
      expect(const NetworkError('x').stackTrace, isNull);
    });
  });

  group('NetworkError.retryable 语义', () {
    test('默认可重试（SSE 断线重连依赖它）', () {
      // 默认 true 是**刻意**的：网络类失败绝大多数是瞬时的。默认 false 会让
      // 每个忘了传参数的调用点都变成「不可重试」，而这是静默的功能退化。
      expect(const NetworkError('超时').retryable, isTrue);
    });

    test('可显式声明不可重试（取消 / 证书错误）', () {
      // 对应 `mapDioError` 里 `cancel` / `badCertificate` 两条分支：重试
      // 一个被用户主动取消的请求，或重试一个证书不受信的连接，都是错的。
      expect(const NetworkError('已取消', retryable: false).retryable, isFalse);
    });
  });

  group('HttpError 状态码谓词', () {
    test('逐码命中（401/403/404/409/429/5xx）', () {
      expect(const HttpError(401, 'x').isUnauthorized, isTrue);
      expect(const HttpError(403, 'x').isForbidden, isTrue);
      expect(const HttpError(404, 'x').isNotFound, isTrue);
      expect(const HttpError(409, 'x').isConflict, isTrue);
      expect(const HttpError(429, 'x').isRateLimited, isTrue);
      // 5xx 是**范围**而非单码，边界要覆盖 500 与 599。
      expect(const HttpError(500, 'x').isServerError, isTrue);
      expect(const HttpError(503, 'x').isServerError, isTrue);
      expect(const HttpError(599, 'x').isServerError, isTrue);
    });

    test('边界：不命中相邻状态码（防止把范围写宽）', () {
      // 4xx 之间**互不串台**。若 isNotFound 被误写成 `>= 400`，下面每条都会挂。
      const codes = [400, 402, 405, 408, 410, 418, 422, 499];
      for (final c in codes) {
        final e = HttpError(c, 'x');
        expect(e.isUnauthorized, isFalse, reason: '$c 不该是 401');
        expect(e.isForbidden, isFalse, reason: '$c 不该是 403');
        expect(e.isNotFound, isFalse, reason: '$c 不该是 404');
        expect(e.isConflict, isFalse, reason: '$c 不该是 409');
        expect(e.isRateLimited, isFalse, reason: '$c 不该是 429');
        expect(e.isServerError, isFalse, reason: '$c 不该是 5xx');
      }
      // 4xx 不是 5xx；499 是边界（< 500）。
      expect(const HttpError(499, 'x').isServerError, isFalse);
    });

    test('statusCode / body 被保留（body 是排查契约漂移的唯一线索）', () {
      const e = HttpError(422, 'HTTP 422', body: '{"error":"字段缺失"}');
      expect(e.statusCode, 422);
      expect(e.body, '{"error":"字段缺失"}');
      expect(const HttpError(500, 'x').body, isNull);
    });
  });

  group('AuthError 语义', () {
    test('401 / 403 各自命中，且 statusCode 被保留', () {
      expect(const AuthError('会话已失效', statusCode: 401).isUnauthorized, isTrue);
      expect(const AuthError('没有权限', statusCode: 403).isForbidden, isTrue);
    });

    test('statusCode 可空（失败发生在发请求之前）', () {
      // 「本地无凭证」「token 响应缺 access_token」这类失败**没有** HTTP 码可归因。
      // 用 0 或 -1 之类的哨兵值会在 UI 上显示成「HTTP 0」这种无意义信息。
      const e = AuthError('本地无凭证');
      expect(e.statusCode, isNull);
      expect(e.isUnauthorized, isFalse);
      expect(e.isForbidden, isFalse);
    });

    test('AuthError 不是 HttpError（这是它存在的理由）', () {
      // 文档明说：用独立类型让 UI 在**编译期**穷举「弹登录页」这条分支，
      // 而不是靠 `statusCode == 401` 的魔法数字。若有人图省事让 AuthError
      // 继承 HttpError，这个 `is HttpError` 断言会挂——那正是要拦住的改动。
      const e = AuthError('过期', statusCode: 401);
      expect(e, isNot(isA<HttpError>()));
      expect(e, isA<SpbError>());
    });
  });

  group('其余子类的语义边界', () {
    test('ParseError 保留 raw（契约漂移时用来比对实际返回）', () {
      const e = ParseError('缺 items 字段', raw: '{"data":[]}');
      expect(e.raw, '{"data":[]}');
      expect(const ParseError('x').raw, isNull);
      // 解析失败**不带** retryable：重试无用（与 NetworkError 的关键区别）。
      expect(e, isNot(isA<NetworkError>()));
    });

    test('StorageError / PlatformError / ValidationError 不带额外状态', () {
      // 它们是「已定位到原因」的失败，不该被当成网络问题重试。
      expect(const StorageError('x'), isNot(isA<NetworkError>()));
      expect(const PlatformError('x'), isNot(isA<NetworkError>()));
      expect(const ValidationError('x'), isNot(isA<NetworkError>()));
      // ValidationError 与 HttpError 的 4xx 看着都像「请求不合法」，但成因不同
      // （本地校验 vs 服务端拒绝）。混为一谈会让「空输入」在日志里像服务端故障。
      expect(const ValidationError('空输入'), isNot(isA<HttpError>()));
    });
  });

  group('编译期穷举（sealed class 的核心价值）', () {
    test('switch 能无 default 地穷举全部子类', () {
      // 这段代码本身就是断言：它**必须能编译**。若新增了子类而忘了在这里
      // 处理，`switch` 表达式会因不穷举而编译失败（配合 `exhaustive` 检查）。
      // 这是 sealed class 相对 `Exception` 的**唯一**结构性优势。
      String label(SpbError e) => switch (e) {
        NetworkError() => 'network',
        HttpError() => 'http',
        ParseError() => 'parse',
        AuthError() => 'auth',
        StorageError() => 'storage',
        PlatformError() => 'platform',
        ValidationError() => 'validation',
        MessageQueuedError() => 'queued',
        MessageDeliveryFailedError() => 'delivery-failed',
      };

      expect(label(const NetworkError('x')), 'network');
      expect(label(const HttpError(500, 'x')), 'http');
      expect(label(const ParseError('x')), 'parse');
      expect(label(const AuthError('x')), 'auth');
      expect(label(const StorageError('x')), 'storage');
      expect(label(const PlatformError('x')), 'platform');
      expect(label(const ValidationError('x')), 'validation');
      // 这两个是「消息进了待发送状态 / 投递最终失败」的**状态信号**，不是
      // 网络失败——UI 靠它们区分「已排队」与「发送失败」（issue #30）。
      expect(label(const MessageQueuedError('x')), 'queued');
      expect(label(const MessageDeliveryFailedError('x')), 'delivery-failed');
    });

    test('MessageQueuedError 不是 NetworkError（UI 靠类型区分「排队」与「失败」）', () {
      // 若图省事复用了 NetworkError，UI 只能笼统说「发送失败：网络错误」——
      // 用户会以为消息丢了、重打一遍（结果发两条）。
      expect(const MessageQueuedError('x'), isNot(isA<NetworkError>()));
      expect(
        const MessageDeliveryFailedError('x'),
        isNot(isA<MessageQueuedError>()),
        reason: '「已排队」与「投递失败」必须是两个可区分的终态',
      );
    });
  });
}

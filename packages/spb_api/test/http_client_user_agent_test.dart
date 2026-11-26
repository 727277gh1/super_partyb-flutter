import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:test/test.dart';

void main() {
  test('默认不覆盖 User-Agent（与其它客户端保持一致）', () {
    final dio = createDio(baseUrl: 'https://api.test/pba');
    expect(dio.options.headers.containsKey('User-Agent'), isFalse);
  });

  test('传入 userAgent 时写进请求头（后台轮询的观测标记）', () {
    final dio = createDio(
      baseUrl: 'https://api.test/pba',
      userAgent: kBackgroundPollUserAgent,
    );
    expect(dio.options.headers['User-Agent'], 'spb-bg/1');
  });

  test('标记串只用于观测：不携带凭证、不含用户信息', () {
    // 它会被写进服务端日志并可能被第三方看到，故必须是常量串。
    expect(kBackgroundPollUserAgent, 'spb-bg/1');
    expect(kBackgroundPollUserAgent, isNot(contains('@')));
  });

  test('标记落在真实请求上（不是只存在 options 里）', () async {
    final seen = <String?>[];
    final dio =
        createDio(
            baseUrl: 'https://api.test/pba',
            userAgent: kBackgroundPollUserAgent,
          )
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                seen.add(options.headers['User-Agent'] as String?);
                handler.reject(
                  DioException(requestOptions: options, error: 'stop'),
                );
              },
            ),
          );
    await expectLater(
      dio.get<dynamic>('/me/notices'),
      throwsA(isA<DioException>()),
    );
    expect(seen, [kBackgroundPollUserAgent]);
  });
}

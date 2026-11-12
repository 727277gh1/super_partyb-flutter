import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// App 扫码登录 API 客户端的契约测试。
///
/// ## 防的是哪些**静默**错误
///
/// - 端点拼错（丢 basePath、多一个斜杠）→ 404，用户只看到「确认失败」；
/// - 忘带 Bearer → 401，但文案若是「网络错误」用户会一直重试；
/// - 把 `status` 的未知值当成 confirmed → 界面显示「已登录」而其实没有；
/// - 深链解析漏了 https 形态 → 系统相机扫码后 App「毫无反应」（最难查的一类）。
void main() {
  const issuer = 'https://dever.atjog.com/idp';
  late Dio dio;
  late DioAdapter adapter;
  late QrLoginClient client;

  setUp(() {
    dio = Dio(BaseOptions(responseType: ResponseType.json));
    adapter = DioAdapter(dio: dio);
    client = QrLoginClient(
      issuer: Uri.parse(issuer),
      tokenProvider: () async => 'idp-access-token',
      dio: dio,
    );
  });

  group('端点推导', () {
    test('从 issuer 推导，保留 /idp 前缀', () {
      expect(
        client.endpointBase.toString(),
        'https://dever.atjog.com/idp/api/v1/qr-login/sessions',
      );
    });

    test('issuer 结尾带斜杠时不产生双斜杠', () {
      final c = QrLoginClient(issuer: Uri.parse('$issuer/'), dio: dio);
      expect(
        c.endpointBase.toString(),
        'https://dever.atjog.com/idp/api/v1/qr-login/sessions',
      );
    });
  });

  group('preview', () {
    test('解析 device / accountName / expiresIn', () async {
      adapter.onGet(
        '$issuer/api/v1/qr-login/sessions/scene-1/preview',
        (server) => server.reply(200, {
          'success': true,
          'status': 'pending',
          'source': '43.174.246.24 · Windows · Chrome',
          'expiresIn': 287,
          'user': {'id': 'user-1', 'name': 'Jim'},
        }),
      );

      final preview = await client.preview('scene-1');
      expect(preview.status, QrLoginStatus.pending);
      // 设备描述必须原样带出来——它是确认页唯一的反钓鱼依据。
      expect(preview.device, '43.174.246.24 · Windows · Chrome');
      expect(preview.accountName, 'Jim');
      expect(preview.expiresInSeconds, 287);
    });

    test('410 过期 → AuthError，文案指向「刷新二维码」', () async {
      adapter.onGet(
        '$issuer/api/v1/qr-login/sessions/old/preview',
        (server) => server.reply(410, {
          'success': false,
          'error': 'expired',
          'message': '二维码已过期',
        }),
      );

      await expectLater(
        client.preview('old'),
        throwsA(
          isA<AuthError>().having((e) => e.message, 'message', contains('刷新')),
        ),
      );
    });

    test('401 → 文案提示重新登录，而不是网络错误', () async {
      final anon = QrLoginClient(
        issuer: Uri.parse(issuer),
        tokenProvider: () async => null,
        dio: dio,
      );
      adapter.onGet(
        '$issuer/api/v1/qr-login/sessions/s/preview',
        (server) =>
            server.reply(401, {'success': false, 'error': 'unauthorized'}),
      );

      await expectLater(
        anon.preview('s'),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('重新登录'),
          ),
        ),
      );
    });
  });

  group('confirm / deny', () {
    test('confirm 发 POST 并带 Content-Type', () async {
      adapter.onPost(
        '$issuer/api/v1/qr-login/sessions/scene-1/confirm',
        (server) => server.reply(200, {'success': true, 'status': 'confirmed'}),
        headers: {
          'Authorization': 'Bearer idp-access-token',
          'Content-Type': 'application/json',
        },
      );

      expect(await client.confirm('scene-1'), QrLoginStatus.confirmed);
    });

    test('deny 发 POST 到 /deny', () async {
      adapter.onPost(
        '$issuer/api/v1/qr-login/sessions/scene-1/deny',
        (server) => server.reply(200, {'success': true, 'status': 'denied'}),
        headers: {
          'Authorization': 'Bearer idp-access-token',
          'Content-Type': 'application/json',
        },
      );

      expect(await client.deny('scene-1'), QrLoginStatus.denied);
    });

    test('409 已被其他账号确认 → 提示重新出码', () async {
      adapter.onPost(
        '$issuer/api/v1/qr-login/sessions/race/confirm',
        (server) =>
            server.reply(409, {'success': false, 'error': 'already_confirmed'}),
        headers: {
          'Authorization': 'Bearer idp-access-token',
          'Content-Type': 'application/json',
        },
      );

      await expectLater(
        client.confirm('race'),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('重新出码'),
          ),
        ),
      );
    });

    test('空 scene 直接拒绝，不发请求', () async {
      await expectLater(client.confirm('   '), throwsA(isA<AuthError>()));
    });
  });

  group('状态解析', () {
    test('未知状态按 pending 处理（宁可多问一次，也不谎报已登录）', () {
      expect(QrLoginClient.parseStatus('weird'), QrLoginStatus.pending);
      expect(QrLoginClient.parseStatus(null), QrLoginStatus.pending);
      expect(QrLoginClient.parseStatus('confirmed'), QrLoginStatus.confirmed);
      expect(QrLoginClient.parseStatus('denied'), QrLoginStatus.denied);
    });
  });

  group('深链解析', () {
    test('自定义 scheme', () {
      final uri = Uri.parse('partyb://qrlogin?scene=abc123');
      expect(QrLoginUri.matches(uri), isTrue);
      expect(QrLoginUri.parseScene(uri), 'abc123');
    });

    test('claimed HTTPS（系统相机扫码的形态，必须认）', () {
      final uri = Uri.parse('https://dever.atjog.com/idp/qr/abc123');
      expect(QrLoginUri.matches(uri), isTrue);
      expect(QrLoginUri.parseScene(uri), 'abc123');
    });

    test('其他环境的 host 同样认（issuer 不进白名单）', () {
      final uri = Uri.parse('https://192.168.1.123:9000/idp/qr/abc123');
      expect(QrLoginUri.parseScene(uri), 'abc123');
    });

    test('OIDC 回调不能被误认成扫码登录', () {
      final uri = Uri.parse('partyb://oidc/callback?code=x&state=y');
      expect(QrLoginUri.matches(uri), isFalse);
      expect(QrLoginUri.parseScene(uri), isNull);
    });

    test('缺少 scene / 只有前缀 → null', () {
      expect(QrLoginUri.parseScene(Uri.parse('partyb://qrlogin')), isNull);
      expect(
        QrLoginUri.parseScene(Uri.parse('https://dever.atjog.com/idp/qr/')),
        isNull,
      );
    });

    test('生成的深链能被自己解析回来（往返一致）', () {
      final link = QrLoginUri.deepLink('a-b_c.d~e');
      expect(QrLoginUri.parseScene(Uri.parse(link)), 'a-b_c.d~e');
    });
  });
}

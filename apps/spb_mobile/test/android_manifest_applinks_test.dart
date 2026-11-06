import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';

/// 平台配置文件与 Dart 常量的一致性守卫。
///
/// ## 为什么需要这组断言
///
/// OIDC 回调地址在**四处**独立声明（见 `packages/spb_api/lib/src/oidc_callback.dart`
/// 的类注释）：Android manifest、iOS Info.plist、IdP `oauth_clients.redirectUris`、
/// Dart 常量。前三处是平台配置文件，**无法 import Dart 常量**，改一处忘另一处
/// 是必然会发生的事，而后果不是报错，是「登录后应用毫无反应」。
///
/// 这里直接读 manifest/plist 文本做断言，把「改了 Dart 常量但忘了改 manifest」
/// 这类漂移变成**测试红灯**，而不是线上排查三小时。
///
/// ## 为什么断言的是「包含」而不是解析 XML
///
/// 只为守卫关键字段，用 `XmlDocument` 会引入依赖并让断言变脆（Flutter 模板
/// 常被工具重排）。文本匹配足够，且失败信息能直接指出缺什么。
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  final plist = File('ios/Runner/Info.plist');

  group('AndroidManifest：自定义 scheme 回调', () {
    test('声明了 partyb://oidc/callback 且与 Dart 常量一致', () {
      expect(manifest.existsSync(), isTrue, reason: '找不到 ${manifest.path}');
      final xml = manifest.readAsStringSync();

      expect(
        xml,
        contains('android:scheme="${OidcCallbackUri.scheme}"'),
        reason: 'scheme 与 OidcCallbackUri.scheme 不一致',
      );
      expect(
        xml,
        contains('android:host="${OidcCallbackUri.host}"'),
        reason: 'host 与 OidcCallbackUri.host 不一致',
      );
      expect(
        xml,
        contains('android:pathPrefix="${OidcCallbackUri.path}"'),
        reason: 'pathPrefix 与 OidcCallbackUri.path 不一致',
      );
    });
  });

  group('AndroidManifest：claimed HTTPS（App Links）', () {
    late String xml;

    setUp(() {
      xml = manifest.readAsStringSync();
    });

    test('存在 autoVerify 的 intent-filter', () {
      expect(
        xml,
        contains('android:autoVerify="true"'),
        reason:
            '没有 autoVerify，Android 不会去取 assetlinks.json，'
            'https 链接永远不会交给本应用',
      );
    });

    test('声明了 https scheme 与 Dart 侧一致的 path', () {
      // path 由 issuer 推导：issuer 的 basePath + /app/callback。
      final expectedPath = OidcCallbackUri.claimedHttpsRedirectUri(
        issuer: Uri.parse('https://app.example.com/idp'),
      )!.path;

      expect(expectedPath, '/idp/app/callback');
      expect(
        xml,
        contains('android:scheme="https"'),
        reason: 'claimed HTTPS 回调需要 https scheme',
      );
      expect(
        xml,
        contains('android:path="$expectedPath"'),
        reason: 'path 与 OidcCallbackUri.claimedHttpsPath（含 issuer basePath）不一致',
      );
    });

    test('双栈两个 host 都已声明', () {
      for (final host in ['app.example.com', 'app2.example.com']) {
        expect(
          xml,
          contains('android:host="$host"'),
          reason: '缺少 $host：该域名下点击回调链接不会被本应用接管',
        );
      }
    });

    test('每个 host 独占一条 autoVerify filter（不能合并）', () {
      // WHY: Android 11 及以下，一条 filter 里**任一** host 验证失败会导致整条
      // filter 失效。tbcc6 目前没有 HTTPS 监听（TLS 只在 EdgeOne 上且只前置
      // tbcc），若与 tbcc 合并在一条 filter 里，会让旧设备上 tbcc 也收不到回调。
      final filters = RegExp(
        r'<intent-filter[^>]*android:autoVerify="true"[^>]*>[\s\S]*?</intent-filter>',
      ).allMatches(xml).map((m) => m.group(0)!).toList();

      expect(filters, hasLength(2), reason: '应为两个域名各一条 autoVerify filter');

      for (final filter in filters) {
        final hosts = RegExp(r'android:host="([^"]+)"')
            .allMatches(filter)
            .map((m) => m.group(1))
            .toList();
        expect(hosts, hasLength(1), reason: '一条 filter 只能有一个 host，实际 = $hosts');
      }
    });

    test('自定义 scheme 的 intent-filter 没有被 autoVerify 误伤', () {
      // autoVerify 只对 http/https 有意义；给 partyb 加 autoVerify 会让
      // Android 尝试校验失败并静默禁用该 filter。
      final schemeFilter = RegExp(
        r'<intent-filter[^>]*>[\s\S]*?android:scheme="partyb"[\s\S]*?</intent-filter>',
      ).firstMatch(xml);
      expect(schemeFilter, isNotNull, reason: '找不到自定义 scheme 的 intent-filter');
      expect(
        schemeFilter!.group(0),
        isNot(contains('autoVerify')),
        reason: '自定义 scheme 不应带 autoVerify',
      );
    });
  });

  group('iOS Info.plist', () {
    test('声明了同一 scheme（iOS 无 claimed HTTPS 前的最低要求）', () {
      expect(plist.existsSync(), isTrue, reason: '找不到 ${plist.path}');
      final xml = plist.readAsStringSync();

      expect(
        xml,
        contains('<string>${OidcCallbackUri.scheme}</string>'),
        reason: 'CFBundleURLSchemes 与 OidcCallbackUri.scheme 不一致',
      );
    });
  });
}

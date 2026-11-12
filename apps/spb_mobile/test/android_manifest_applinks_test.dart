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
        issuer: Uri.parse('https://tbcc.atjog.com/idp'),
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

    test('各环境 issuer host 都已声明', () {
      // 断言的是「每个跑过 OIDC 的 issuer 域名都在」，不是固定条数：
      // 漏一条不报错、只是那个环境「回调打开浏览器落地页」，要多点一次「打开应用」。
      for (final host in [
        'tbcc.atjog.com', // 生产
        'tbcc6.atjog.com', // 生产双栈别名
        'dever.atjog.com', // 内网 dever 环境
      ]) {
        expect(
          xml,
          contains('android:host="$host"'),
          reason: '缺少 $host：该域名下点击回调链接不会被本应用接管',
        );
      }
    });

    test('每条 autoVerify filter 只声明一个 host（不能合并）', () {
      // WHY: Android 11 及以下，一条 filter 里**任一** host 验证失败会导致整条
      // filter 失效。tbcc6 目前没有 HTTPS 监听（TLS 只在 EdgeOne 上且只前置
      // tbcc），若与 tbcc 合并在一条 filter 里，会让旧设备上 tbcc 也收不到回调。
      // 这里不写死 filter 条数：manifest 里还有其它用途的 autoVerify 组
      // （例如其它深链），断言只应关心「一条一 host」这条不变量。
      final filters = _autoVerifyFilters(xml);
      expect(filters, isNotEmpty, reason: '找不到 autoVerify filter');

      for (final filter in filters) {
        final hosts = _hostsOf(filter);
        expect(
          hosts,
          hasLength(1),
          reason: '一条 filter 只能有一个 host，实际 = $hosts\n$filter',
        );
      }
    });

    test('每个 issuer host 各有一条 /idp/app/callback 的 filter', () {
      final callbackFilters = _autoVerifyFilters(xml)
          .where((f) => f.contains('android:path="/idp/app/callback"'))
          .toList();
      final hosts = callbackFilters.expand(_hostsOf).toSet();

      for (final host in [
        'tbcc.atjog.com',
        'tbcc6.atjog.com',
        'dever.atjog.com',
      ]) {
        expect(
          hosts,
          contains(host),
          reason: '缺少 $host 的回调 filter：该域名下点击回调只会在浏览器落地页停下',
        );
      }
      expect(
        hosts.length,
        callbackFilters.length,
        reason: '回调 filter 有 host 重复：$hosts vs ${callbackFilters.length} 条',
      );
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

/// 取出 manifest 里所有 `autoVerify="true"` 的 intent-filter 文本块。
List<String> _autoVerifyFilters(String xml) => RegExp(
  r'<intent-filter[^>]*android:autoVerify="true"[^>]*>[\s\S]*?</intent-filter>',
).allMatches(xml).map((m) => m.group(0)!).toList();

/// 取出一个 filter 块里的全部 host。
List<String> _hostsOf(String filter) =>
    RegExp(r'android:host="([^"]+)"')
        .allMatches(filter)
        .map((m) => m.group(1)!)
        .toList();

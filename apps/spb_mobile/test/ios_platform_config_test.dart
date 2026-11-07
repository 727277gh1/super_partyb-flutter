import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';

/// iOS 平台配置守卫（Associated Domains / 微信 OpenSDK）。
///
/// ## 为什么需要这组断言
///
/// iOS 侧的三件事都**没有任何编译期检查**，错了也不报错，只是「点了没反应」：
///
/// 1. `Runner.entitlements` 里的 Associated Domains —— 少了它，OIDC 的
///    claimed HTTPS 回调（`https://<host>/idp/app/callback`）与微信的
///    Universal Link 都落不到本 App；
/// 2. `CODE_SIGN_ENTITLEMENTS` —— 少了它，entitlements 文件**存在但完全不生效**
///    （这是最容易踩的一步：文件在、内容对、就是不起作用）；
/// 3. `LSApplicationQueriesSchemes` —— 少了 `weixin`，
///    `fluwx.isWeChatInstalled` 恒为 false，登录页会判定「微信未安装」。
///
/// 本机是 Debian（无 Xcode、无 iOS 工具链），既不能构建也不能真机验证，
/// 所以这里退而求其次：直接读文本断言**配置之间的一致性**，把「改了 A 忘了 B」
/// 变成测试红灯。真机验证仍归 issue #4。
/// 去掉 XML 注释后再断言。
///
/// 平台配置文件里的注释带着**示例值**（`wx1234567890abcdef`、`applinks:…`），
/// 直接 `contains` 会被注释蒙混过关——反向验证（注入 appid 但不改 plist）
/// 时这条断言假绿过一次，所以才有了这个函数。
String _stripXmlComments(String xml) =>
    xml.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

void main() {
  final entitlements = File('ios/Runner/Runner.entitlements');
  final plist = File('ios/Runner/Info.plist');
  final pbxproj = File('ios/Runner.xcodeproj/project.pbxproj');
  final manifest = File('android/app/src/main/AndroidManifest.xml');

  group('Associated Domains（Runner.entitlements）', () {
    test('文件存在且声明了 associated-domains', () {
      expect(
        entitlements.existsSync(),
        isTrue,
        reason: '找不到 ${entitlements.path}：iOS 侧无法接管任何 https 回调',
      );
      final xml = _stripXmlComments(entitlements.readAsStringSync());
      expect(
        xml,
        contains('<key>com.apple.developer.associated-domains</key>'),
        reason: '缺少 associated-domains 键，entitlements 形同虚设',
      );
    });

    test('与 Android App Links 声明**同一组**域名（跨平台一致性）', () {
      // 两端各自硬编码域名，改一处忘另一处时：Android 能接管、iOS 不能
      // （或反之），表现为「同一个账号在某个平台上登录后回不来」。
      final androidHosts = RegExp(r'android:host="([^"]+)"')
          .allMatches(manifest.readAsStringSync())
          .map((m) => m.group(1)!)
          .where((h) => h.contains('.')) // 排除自定义 scheme 的 `oidc`
          .toSet();
      expect(
        androidHosts,
        isNotEmpty,
        reason: 'Android manifest 里没找到 claimed HTTPS 的 host',
      );

      final xml = _stripXmlComments(entitlements.readAsStringSync());
      for (final host in androidHosts) {
        expect(
          xml,
          contains('<string>applinks:$host</string>'),
          reason:
              'entitlements 缺 applinks:$host，但 Android manifest 声明了它：'
              '该域名下的回调在 iOS 上不会被本 App 接管',
        );
      }
    });

    test('微信 Universal Link 的域名在声明范围内', () {
      // fluwx.registerApi(universalLink: ...) 的域名必须出现在 associated
      // domains 里，否则微信无法把用户从微信带回 App（issue #92）。
      // 未注入该 dart-define 时跳过：此时 OpenSDK 通道本就判定为不可用。
      const link = SpbEnv.wechatUniversalLink;
      if (link.isEmpty) return;

      final host = Uri.tryParse(link)?.host ?? '';
      expect(
        host,
        isNotEmpty,
        reason: 'SPB_WECHAT_UNIVERSAL_LINK 不是合法 URL：$link',
      );
      expect(
        _stripXmlComments(entitlements.readAsStringSync()),
        contains('<string>applinks:$host</string>'),
        reason: 'Universal Link 域名 $host 未在 entitlements 中声明，微信回不来',
      );
    });
  });

  group('Info.plist（微信 OpenSDK）', () {
    late String xml;

    setUp(() {
      xml = _stripXmlComments(plist.readAsStringSync());
    });

    test('LSApplicationQueriesSchemes 覆盖微信 SDK 要求的 scheme', () {
      // 缺 weixin → isWeChatInstalled 恒 false；缺 weixinULAPI →
      // 「唤起成功但回不来」。两者都不报错，只表现为功能不可用。
      expect(
        xml,
        contains('<key>LSApplicationQueriesSchemes</key>'),
        reason: '没有 scheme 白名单，canOpenURL 对微信一律返回 false',
      );
      for (final scheme in ['weixin', 'weixinULAPI', 'weixinURLParamsAPI']) {
        expect(
          xml,
          contains('<string>$scheme</string>'),
          reason: '缺少 $scheme：微信 OpenSDK 的对应能力会静默失效',
        );
      }
    });

    test('注入了 SPB_WECHAT_OPEN_APP_ID 时，回跳 scheme 已补进 CFBundleURLTypes', () {
      // `wx<AppID>` 这个 scheme 无法预先写死（AppID 来自开放平台审核结果），
      // 也不受 --dart-define 影响（那只进 Dart 侧），只能人工补进 plist。
      // 这里在「构建时确实注入了 AppID」的前提下把人工步骤变成红灯提醒。
      const appId = SpbEnv.wechatOpenAppId;
      if (appId.isEmpty) return;

      expect(
        xml,
        contains('<string>$appId</string>'),
        reason:
            '已注入 $appId，但 Info.plist 的 CFBundleURLTypes 里没有它：'
            '微信里点「返回App」不会有反应（登录最终仍能完成，体验降级）',
      );
    });
  });

  group('project.pbxproj（entitlements 是否真的挂上了）', () {
    late String project;

    setUp(() {
      project = pbxproj.readAsStringSync();
    });

    test('entitlements 文件被工程引用', () {
      expect(
        project,
        contains('Runner.entitlements'),
        reason: '工程里没有引用 entitlements 文件，Xcode 里也看不到它',
      );
    });

    test('Runner target 的三个构建配置都设置了 CODE_SIGN_ENTITLEMENTS', () {
      // 只设 Debug 是最常见的漏法：本地调试正常，Release 包上线后
      // Universal Link / App Links 全部失效，而且无法从崩溃日志看出来。
      // 每个 XCBuildConfiguration 块形如：
      //   <uuid> /* Debug */ = { isa = XCBuildConfiguration; ... name = Debug; };
      // 用非贪婪匹配到 `name = X;` 后的 `};`，块内再找包名与 entitlements。
      final configs = RegExp(
        r'isa = XCBuildConfiguration;[\s\S]*?name = (\w+);\n\t\t\};',
      ).allMatches(project).map((m) => (m.group(1)!, m.group(0)!)).toList();

      final runnerConfigs = configs
          .where(
            (c) => c.$2.contains(
              'PRODUCT_BUNDLE_IDENTIFIER = com.atjog.spb.spbMobile;',
            ),
          )
          .toList();

      expect(
        runnerConfigs.map((c) => c.$1).toSet(),
        {'Debug', 'Release', 'Profile'},
        reason:
            'Runner target 应有 Debug/Release/Profile 三个配置，实际 '
            '${runnerConfigs.map((c) => c.$1).toList()}',
      );

      for (final (name, block) in runnerConfigs) {
        expect(
          block,
          contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'),
          reason: '配置 $name 没有挂 CODE_SIGN_ENTITLEMENTS：该构建的 entitlements 不生效',
        );
      }
    });
  });
}

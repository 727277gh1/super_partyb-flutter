import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_desktop/app.dart';
import 'package:spb_desktop/providers.dart';

void main() {
  testWidgets('主窗口能渲染骨架页', (tester) async {
    // 显式注入空实现：测试环境没有真实窗口/托盘，
    // 不注入会让插件调用失败。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopCapabilitiesProvider.overrideWithValue(
            const NoopDesktopCapabilities(),
          ),
        ],
        child: const SpbDesktopApp(),
      ),
    );

    expect(find.text('Super PartyB'), findsOneWidget);
    expect(find.text('桌面端骨架已就绪'), findsOneWidget);
  });
}

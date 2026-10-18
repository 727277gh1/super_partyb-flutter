import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 为 golden 测试装载**确定性字体**。
///
/// ## 为什么必须显式装载
///
/// `flutter test` 默认用 **Ahem**（每个字形渲染成一个实心方块）——这保证
/// 「文字内容变了 golden 也会变」，但**基线图无法人工审阅**：一张全是方块的
/// PNG 看不出「按钮是不是错位了」。
///
/// 显式装载 Roboto + MaterialIcons 后，拉丁字母与图标真实渲染，基线可读。
///
/// ## 为什么从 `FLUTTER_ROOT` 取，而不是打进仓库
///
/// `bin/cache/artifacts/material_fonts/` 里的字体**随 Flutter 版本锁定**
/// （本仓库锁 3.47.5，见 `AGENTS.md` §9）。CI 的 `subosito/flutter-action`
/// 下载同一版本，故**本机与 CI 拿到的是逐字节相同的字体**——这正是
/// golden「两处都过」的前提。
///
/// 反过来，若用系统字体（`/usr/share/fonts/...`），本机 Debian 与 CI 的
/// ubuntu-latest 字体集不同 → 基线在两处渲染不同 → 必然有一边失败。
///
/// ## 已知限制：中日韩文字渲染成 tofu
///
/// SDK 里**没有** CJK 字体（只有 Roboto / MaterialIcons）。中文文案会渲染成
/// 空心方块（tofu）。这**不影响** golden 的用途——它锁的是**布局**（位置、
/// 尺寸、间距、颜色、换行点），tofu 与真字形在这些维度上完全一致。
///
/// 故写 golden 用例时：
/// - 需要**看清文案**的断言用普通 `expect(find.text(...))`，不要靠 golden；
/// - golden 只用来抓「布局/样式改坏了」。
///
/// ## 用法
///
/// ```dart
/// setUpAll(loadGoldenFonts);
///
/// testWidgets('...', (tester) async {
///   await tester.pumpWidget(goldenHost(const ErrorBanner(message: 'x')));
///   await expectLater(
///     find.byType(ErrorBanner),
///     matchesGoldenFile('goldens/error_banner.png'),
///   );
/// });
/// ```
Future<void> loadGoldenFonts() async {
  final root = _flutterRoot();
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) {
    // 静默降级：字体目录不存在时回退到 Ahem。测试仍会跑（基线不匹配则失败，
    // 提示信息已足够定位）。不抛异常——那会让「CI 上没有该目录」变成整个
    // 测试套件崩溃，而不是一条 golden 失败。
    return;
  }

  const families = <String, List<String>>{
    'Roboto': ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf'],
    'MaterialIcons': ['MaterialIcons-Regular.otf'],
  };

  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    var loaded = false;
    for (final name in entry.value) {
      final file = File('${dir.path}/$name');
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      loader.addFont(
        Future.value(ByteData.view(bytes.buffer, bytes.offsetInBytes)),
      );
      loaded = true;
    }
    if (loaded) await loader.load();
  }
}

/// 定位 Flutter SDK 根目录。
///
/// 优先用 `FLUTTER_ROOT`（`flutter test` 会设置）。缺失时从
/// `Platform.resolvedExecutable` 反推——测试进程就是
/// `<root>/bin/cache/artifacts/engine/<platform>/flutter_tester`，
/// 故上溯 5 层即根目录。**不依赖环境变量**这一点很重要：CI 的
/// action 是否导出 `FLUTTER_ROOT` 不在本仓库控制范围内。
String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

  // .../bin/cache/artifacts/engine/<platform>/flutter_tester
  return File(Platform.resolvedExecutable)
      .parent
      .parent
      .parent
      .parent
      .parent
      .path;
}

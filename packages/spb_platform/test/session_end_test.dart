import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// 「宿主会话即将结束」接线（§6.87）。
///
/// ## 为什么这组用例必须存在
///
/// 这条通道的失败形态是**完全静默**的：通道名写错 → Dart 侧收不到请求 →
/// 安装包升级时客户端照旧不退 → 安装程序停在「正在关闭应用」。没有任何
/// 编译期或行为级信号，只有把「原生侧发来这个动作时会怎样」钉住才拦得住。
///
/// 与 `window_close_test.dart` 同一取向：直接断言**回调被调用了几次**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 模拟原生侧发来一个动作。
  Future<void> sendPlatformAction(String method) async {
    await messenger.handlePlatformMessage(
      kHostLifecycleChannelName,
      codec.encodeMethodCall(MethodCall(method)),
      null,
    );
  }

  tearDown(uninstallSessionEndHandler);

  test('sessionEnding 触发回调', () async {
    var calls = 0;
    installSessionEndHandler(() async => calls++);

    await sendPlatformAction('sessionEnding');

    expect(calls, 1);
  });

  test('未知动作被忽略（不触发回调、不抛）', () async {
    var calls = 0;
    installSessionEndHandler(() async => calls++);

    await sendPlatformAction('somethingElse');

    expect(calls, 0);
  });

  test('重复安装是替换而不是叠加（回调只跑一次）', () async {
    var first = 0;
    var second = 0;
    installSessionEndHandler(() async => first++);
    installSessionEndHandler(() async => second++);

    await sendPlatformAction('sessionEnding');

    expect(first, 0);
    expect(second, 1);
  });

  test('uninstall 后不再响应（detach 的契约）', () async {
    var calls = 0;
    installSessionEndHandler(() async => calls++);
    await sendPlatformAction('sessionEnding');
    expect(calls, 1);

    uninstallSessionEndHandler();
    await sendPlatformAction('sessionEnding');
    expect(calls, 1);
  });
}

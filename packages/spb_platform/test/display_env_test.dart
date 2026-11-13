import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 远端桌面（RDP）会话探测：`com.atjog.spb/display_env` 的 Dart 侧（issue #110）。
///
/// ## 这组用例防的是什么
///
/// 这条探测的**所有**失败模式都是静默的：
///
/// - 通道名 / 方法名写错 → `MissingPluginException`，而它被当作「本平台没有
///   实现」**正常**吞掉（Linux/macOS 确实没有）→ 远端会话永远识别不出来，
///   应用照旧可用，没有任何报障信号；
/// - 异常时把旧值清成 `null` → 诊断报告里出现「(未知)」，而实际早已探测过；
/// - 移动端（预期内没有这条通道）写一条 `warn` → 报告里凭空多出噪声。
///
/// 故这里对「成功 / 无实现 / 调用失败」三条分支各自断言返回值与缓存状态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(kDisplayEnvChannelName);

  setUp(() {
    SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
    SpbLog.clearRecentLogs();
    SpbDisplayEnv.debugSetRemoteSession(null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SpbLog.clearRecentLogs();
    SpbDisplayEnv.debugSetRemoteSession(null);
  });

  void mockHandler(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  test('原生返回 true → 远端会话，并写进进程级缓存', () async {
    mockHandler((call) async {
      expect(call.method, 'remoteSession');
      return true;
    });

    expect(await SpbDisplayEnv.detectRemoteSession(), isTrue);
    // 缓存是「诊断报告 / 动效策略」的唯一数据源（两者都是同步读）。
    expect(SpbDisplayEnv.remoteSession, isTrue);
  });

  test('原生返回 false → 本地会话（false 必须与「未知」区分）', () async {
    mockHandler((call) async => false);

    expect(await SpbDisplayEnv.detectRemoteSession(), isFalse);
    expect(SpbDisplayEnv.remoteSession, isFalse);
  });

  test('本平台没有这条通道 → null，且不写 warn（Linux/macOS/移动端是预期）', () async {
    // 不注册 handler 就等于原生侧没有实现。
    expect(await SpbDisplayEnv.detectRemoteSession(), isNull);
    expect(SpbDisplayEnv.remoteSession, isNull);

    // 移动端每次启动都会走这条分支写 warn 的话，诊断报告里会多出一条永远
    // 无人能处理的噪声。
    expect(
      SpbLog.recentLogs.where((r) => r.level == LogLevel.warn),
      isEmpty,
      reason: '「本平台没有实现」是预期路径，不该 warn',
    );
  });

  test('通道调用失败 → 保留旧值并留一条可查的 warn', () async {
    SpbDisplayEnv.debugSetRemoteSession(true); // 上一轮已探测到远端会话
    mockHandler((call) async => throw PlatformException(code: 'boom'));

    expect(await SpbDisplayEnv.detectRemoteSession(), isTrue);
    expect(SpbDisplayEnv.remoteSession, isTrue, reason: '失败不该把已知结论清掉');

    expect(
      SpbLog.recentLogs.any(
        (r) => r.level == LogLevel.warn && r.message.contains('显示环境探测失败'),
      ),
      isTrue,
      reason: '原生侧未注册 handler / messenger 已销毁时必须能查',
    );
  });

  test('探测成功时写一条 info（报障时「当时是远端会话」的证据）', () async {
    mockHandler((call) async => true);

    await SpbDisplayEnv.detectRemoteSession();

    expect(
      SpbLog.recentLogs.any(
        (r) =>
            r.message.contains('显示环境探测') && r.fields['remote_session'] == true,
      ),
      isTrue,
    );
  });
}

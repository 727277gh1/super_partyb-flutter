import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// [spawnSystemOpen] 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 三平台命令分派此前散在两处、其中一处只实现了 Linux（OIDC 登录与 Markdown
/// 链接点击在 Windows/macOS 上抛 `PlatformError`）。本机是 Linux，macOS /
/// Windows 分支**无法真机验证**，故通过 [ProcessRunner] 注入来断言：
///
/// 1. 每个平台 spawn 的**可执行文件名**正确（`xdg-open` / `open` / `explorer`）；
/// 2. 目标作为**单个参数**传递（不经 shell，路径含空格不会被拆）；
/// 3. 退出码非 0 → `false`；
/// 4. runner 抛异常（可执行文件不存在）→ `false`，不向上抛；
/// 5. [HostPlatform.other] → `false` 且**不 spawn**（静默成功比报错更糟）。
///
/// 这些断言是「macOS 分支是否真的对」的唯一自动化保障——没有它，那个分支要
/// 等到 macOS 用户点登录失败才发现。
void main() {
  /// 记录调用并返回预设退出码的假 runner。
  late List<(String, List<String>)> calls;
  late int exitCode;
  late Object? throwThis;

  ProcessRunner fakeRunner() => _FakeRunner(
    onRun: (exe, args) {
      calls.add((exe, args));
      if (throwThis != null) throw throwThis!;
      return ProcessResult(1, exitCode, '', '');
    },
  );

  setUp(() {
    calls = [];
    exitCode = 0;
    throwThis = null;
  });

  group('平台 → 可执行文件', () {
    test('linux 用 xdg-open', () async {
      final ok = await spawnSystemOpen(
        'https://example.com/login',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'xdg-open');
      expect(calls.single.$2, ['https://example.com/login']);
    });

    test('macos 用 open', () async {
      final ok = await spawnSystemOpen(
        'https://example.com/login',
        platform: HostPlatform.macos,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'open');
      expect(calls.single.$2, ['https://example.com/login']);
    });

    test('windows 用 explorer', () async {
      final ok = await spawnSystemOpen(
        r'C:\Users\me\file.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'explorer');
      expect(calls.single.$2, [r'C:\Users\me\file.md']);
    });

    test('other 返回 false 且不 spawn', () async {
      final ok = await spawnSystemOpen(
        'https://example.com',
        platform: HostPlatform.other,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('参数传递', () {
    test('目标作为单个参数传，含空格/引号不拆分', () async {
      const target = '/home/me/My Docs/a "quoted" file.md';

      await spawnSystemOpen(
        target,
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      // 只传一个参数：Process.run 不经过 shell，故无需（也不应）手工加引号。
      expect(calls.single.$2, [target]);
      expect(calls.single.$2.length, 1);
    });

    test('空目标返回 false 且不 spawn（避免打开主目录）', () async {
      final ok = await spawnSystemOpen(
        '',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('失败降级（返回 false，不抛异常）', () {
    test('退出码非 0 → false', () async {
      exitCode = 3;

      final ok = await spawnSystemOpen(
        'https://example.com',
        platform: HostPlatform.macos,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      // 关键：确实尝试过 spawn（不是提前 return）。
      expect(calls.length, 1);
    });

    test('runner 抛异常（可执行文件不存在）→ false，不向上抛', () async {
      throwThis = const ProcessException('xdg-open', ['https://example.com']);

      // expectLater + completes：断言它**正常返回**而不是抛异常。
      final ok = await spawnSystemOpen(
        'https://example.com',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls.length, 1);
    });

    test('runner 抛任意异常也降级为 false', () async {
      throwThis = StateError('boom');

      final ok = await spawnSystemOpen(
        '/tmp/x',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
    });
  });

  group('HostPlatform.current', () {
    test('在 Linux 测试机上推导出 HostPlatform.linux', () {
      // 本测试运行在 Linux CI / 开发机上；若将来在 macOS runner 上跑会失败，
      // 那时按运行平台放宽（此处刻意写死以便发现「CI 平台变了」）。
      expect(HostPlatform.current(), HostPlatform.linux);
    });

    test('三平台枚举值互不相等（switch 穷举的前提）', () {
      expect(HostPlatform.values.toSet().length, HostPlatform.values.length);
    });
  });

  test('SystemProcessRunner 真实 spawn 一个不存在的命令 → 抛 ProcessException', () async {
    // 这条测的是「真实实现确实会抛」——spawnSystemOpen 的 try/catch 依赖它。
    // 若 ProcessRunner 的实现改成吞异常，上面的降级断言就会失去意义。
    const runner = SystemProcessRunner();
    await expectLater(
      runner.run('/no/such/executable-xyz', const []),
      throwsA(isA<ProcessException>()),
    );
  });
}

/// 记录调用的假 runner。
class _FakeRunner implements ProcessRunner {
  _FakeRunner({required this.onRun});

  final ProcessResult Function(String exe, List<String> args) onRun;

  @override
  Future<ProcessResult> run(String exe, List<String> args) async =>
      onRun(exe, args);
}

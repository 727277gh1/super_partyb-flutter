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
/// 3. 退出码不表示成功 → `false`；
/// 4. runner 抛异常（可执行文件不存在）→ `false`，不向上抛；
/// 5. [HostPlatform.other] → `false` 且**不 spawn**（静默成功比报错更糟）；
/// 6. **Windows 的退出码 1 视为成功**（`explorer` 委托后即退出，成功也返回 1）；
/// 7. **Windows 上 URL 走 `rundll32` 而不是 `explorer`**，且该分支**不据退出码
///    判定**（`rundll32` 恒返回 0，判了也只是把「无法判定」伪装成「已判定」）。
///
/// 这些断言是「macOS / Windows 分支是否真的对」的唯一自动化保障——没有它，
/// 那些分支要等到对应平台的用户点登录失败才发现。
///
/// ## ⚠️ 第 6、7 组各防一个**真实的假绿**
///
/// - 第 6 组：修复前假 runner 在所有「成功」用例里返回 `exitCode = 0`，于是
///   「`explorer` 成功也返回 1」这条平台事实**从未被断言**。而实现按「非 0 即
///   失败」判定——Windows 上每一次成功的打开都被判成失败。
/// - 第 7 组：修复前 Windows **一律** spawn `explorer`，而 `explorer <带 query
///   的 URL>` 打开的是**文件浏览器**（SSO 登录因此每次「成功」地打开一个空
///   窗口，客户端却继续等 loopback 回调）。断言只覆盖了「可执行文件名」而不区分
///   URL/路径形态，那条缺陷因此从未被任何用例碰到。
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

    test('windows 路径用 explorer', () async {
      final ok = await spawnSystemOpen(
        r'C:\Users\me\file.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'explorer');
      expect(calls.single.$2, [r'C:\Users\me\file.md']);
    });

    test('windows 带 query 的 URL 用 rundll32（不是 explorer）', () async {
      // 这是 SSO 登录的真实形态：OIDC 授权 URL 必然带 8 个 query 参数。
      // `explorer <该 URL>` 会打开一个**文件浏览器窗口**（microsoft/WSL#3832），
      // 且退出码仍算成功——用户看到「点了没反应」+ 一个莫名的窗口。
      const url =
          'https://app.example.com/idp/oauth2/authorize'
          '?response_type=code&client_id=flutter-client&redirect_uri=http%3A%2F%2F127.0.0.1%3A8347%2Fcallback'
          '&scope=openid&state=st_1&nonce=no_1&code_challenge=abc&code_challenge_method=S256';

      final ok = await spawnSystemOpen(
        url,
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'rundll32');
      // 参数必须是「dll 函数名」+「完整 URL」两段：URL 原样传递（含 `&`），
      // 不经 shell 故不会被拆成命令分隔符。
      expect(calls.single.$2, ['url.dll,FileProtocolHandler', url]);
      expect(calls.single.$2.length, 2);
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
    test('退出码非成功 → false', () async {
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

    test('linux 的退出码 1 → false（不随 Windows 放宽）', () async {
      // `xdg-open` 有正常的退出码语义：1 表示「没有默认程序」等真实故障。
      // 若把 Windows 的「1 也算成功」误用到全平台，这条会失败。
      exitCode = 1;

      final ok = await spawnSystemOpen(
        'https://example.com',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
    });

    test('macos 的退出码 1 → false（不随 Windows 放宽）', () async {
      exitCode = 1;

      final ok = await spawnSystemOpen(
        '/tmp/x',
        platform: HostPlatform.macos,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
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

  group('Windows 的退出码语义（explorer 成功也返回 1）', () {
    test('windows 文件路径退出码 1 → 视为成功', () async {
      // 这是 Windows 上的**正常路径**：`explorer <路径>` 把请求转交给已运行
      // 的 shell 后自己立即退出，退出码 1（microsoft/WSL#6565）。
      // 修复前此处返回 false，导致每次成功打开都被判失败。
      exitCode = 1;

      final ok = await spawnSystemOpen(
        r'C:\Users\me\Downloads',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'explorer');
      expect(calls.single.$2, [r'C:\Users\me\Downloads']);
    });

    test('windows 退出码 0 → 视为成功', () async {
      exitCode = 0;

      final ok = await spawnSystemOpen(
        r'C:\Users\me\file.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
    });

    test('windows 退出码 2 → false（仍能报出真实失败）', () async {
      // 放宽到 {0,1} 而不是「Windows 一律成功」：其它退出码仍是失败信号，
      // 否则「spawn 了但确实出错」会变成静默成功。
      exitCode = 2;

      final ok = await spawnSystemOpen(
        r'C:\Users\me\file.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls.length, 1);
    });

    test('windows URL（rundll32）不据退出码判定 → 退出码 2 也算已发起', () async {
      // `rundll32` 的退出码**恒为 0**，与「URL 是否真的被打开」无关（上游确认：
      // "rundll32 does not give you any return value, its exit code is always
      // zero"）。故该分支显式跳过退出码判定——否则「换个退出码」会让
      // Windows 登录行为再次反转，而用户什么都看不出来。
      exitCode = 2;

      final ok = await spawnSystemOpen(
        'https://example.com/login?state=st_1',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'rundll32');
    });

    test('windows URL 的 spawn 异常仍降级为 false', () async {
      // 「不看退出码」不等于「吞掉 spawn 失败」：可执行文件不存在仍要报 false，
      // 否则登录页会静静地等到 5 分钟超时。
      throwThis = const ProcessException('rundll32', []);

      final ok = await spawnSystemOpen(
        'https://example.com/login',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls.length, 1);
    });
  });

  group('looksLikeUrl（Windows 命令分派的分支依据）', () {
    test('带 scheme:// 的 URL → true', () {
      expect(looksLikeUrl('https://example.com/a?b=1'), isTrue);
      expect(looksLikeUrl('http://127.0.0.1:8347/callback'), isTrue);
      expect(looksLikeUrl('file:///tmp/x.md'), isTrue);
      expect(looksLikeUrl('partyb://oidc/callback?code=x'), isTrue);
      // 只认 `scheme://`：`mailto:` / `C:` 这类单冒号形态不算（后者正是 Windows
      // 盘符路径被 Uri.parse 误判成 scheme 的那种情形）。
      expect(looksLikeUrl('mailto:me@example.com'), isFalse);
    });

    test('Windows 盘符路径 → false（Uri.parse 会把它解出 scheme=c，不能用它判定）', () {
      // 实测：`Uri.parse(r'C:\Users\me\file.md')` 得到 scheme=`c`、
      // path=`/Users/me/file.md`。若按「scheme 非空」判定，**每个** Windows
      // 文件路径都会走进 URL 分支（交给 rundll32），比原缺陷更难查。
      expect(looksLikeUrl(r'C:\Users\me\file.md'), isFalse);
      expect(looksLikeUrl('C:/Users/me/file.md'), isFalse);
      expect(looksLikeUrl(r'\\server\share\x.md'), isFalse);
    });

    test('Unix 路径 / 相对路径 / 空串 → false', () {
      expect(looksLikeUrl('/home/me/x.md'), isFalse);
      expect(looksLikeUrl('x.md'), isFalse);
      expect(looksLikeUrl(''), isFalse);
    });
  });

  group('spawnSystemReveal（在文件管理器中定位条目）', () {
    // ## 这个 group 防的是什么
    //
    // 修复前 `revealPath` 在三个平台上都不工作，两个独立原因：
    //
    // 1. 实现用 `Directory(path).exists()` 校验——对**文件**恒为 false，于是
    //    「在文件管理器中定位」在 spawn 之前就返回了；
    // 2. 即使放行，Windows 分支 spawn 的是 `explorer <path>`——那是**用默认
    //    程序打开**，不是定位（文件交给 Word/编辑器打开，或无关联时什么都不发生）。
    //
    // 这两个都不报错，用户只看到「点了没反应」。故这里逐平台钉住**参数形态**。

    test('windows 用 explorer /select,（与路径同一个参数）', () async {
      final ok = await spawnSystemReveal(
        r'C:\Users\me\Downloads\a.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'explorer');
      // ⚠️ 必须是**一个**参数：写成 ['/select,', path] 时 explorer 把
      // `/select,` 当成要打开的路径，行为不可预测（explorer 的参数解析不走
      // 标准 CRT）。
      expect(calls.single.$2, [r'/select,C:\Users\me\Downloads\a.md']);
      expect(calls.single.$2.length, 1);
    });

    test('windows 路径含空格也不加引号（Process.run 不经 shell）', () async {
      const target = r'C:\Users\me\My Docs\a b.md';

      await spawnSystemReveal(
        target,
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      // 加引号会让引号成为路径的一部分（Windows 侧自己处理参数边界）。
      expect(calls.single.$2, ['/select,$target']);
    });

    test('macos 用 open -R', () async {
      final ok = await spawnSystemReveal(
        '/Users/me/Downloads/a.md',
        platform: HostPlatform.macos,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'open');
      // -R = reveal in Finder（`open` 本身是「用默认程序打开」）。
      expect(calls.single.$2, ['-R', '/Users/me/Downloads/a.md']);
    });

    test('linux 退化为打开父目录（xdg-open 无选中概念）', () async {
      final ok = await spawnSystemReveal(
        '/home/me/Downloads/reports/a.md',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'xdg-open');
      expect(calls.single.$2, ['/home/me/Downloads/reports']);
    });

    test('linux 尾斜杠被剥掉后再取父目录', () async {
      await spawnSystemReveal(
        '/home/me/Downloads/reports/',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      // 不剥尾斜杠会得到 `/home/me/Downloads/reports`（把目录本身当成条目名，
      // 打开的是它的**父**目录——用户看到的是上一级，与期望差一层）。
      expect(calls.single.$2, ['/home/me/Downloads']);
    });

    test('other 返回 false 且不 spawn', () async {
      final ok = await spawnSystemReveal(
        '/tmp/x.md',
        platform: HostPlatform.other,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('空目标返回 false 且不 spawn', () async {
      final ok = await spawnSystemReveal(
        '',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('linux 无法推导父目录（相对路径）→ false，不 spawn', () async {
      final ok = await spawnSystemReveal(
        'a.md',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('windows 退出码 1 视为成功（explorer 的常态）', () async {
      exitCode = 1;

      final ok = await spawnSystemReveal(
        r'C:\Users\me\a.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isTrue);
    });

    test('windows 退出码 2 → false', () async {
      exitCode = 2;

      final ok = await spawnSystemReveal(
        r'C:\Users\me\a.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
    });

    test('linux 退出码 1 → false（不随 Windows 放宽）', () async {
      exitCode = 1;

      final ok = await spawnSystemReveal(
        '/home/me/a.md',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
    });

    test('spawn 异常降级为 false，不向上抛', () async {
      throwThis = const ProcessException('explorer', []);

      final ok = await spawnSystemReveal(
        r'C:\Users\me\a.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
      );

      expect(ok, isFalse);
      expect(calls.length, 1);
    });
  });

  group('revealSystemEntry（目录就打开、文件就选中）', () {
    // ## 这个 group 防的是什么
    //
    // 「定位」的完整语义有两半，此前**两半都不对**：
    //
    // 1. 只接受目录（`Directory(path).exists()` 对文件恒 false）→ 传文件时
    //    在 spawn 之前就返回了；
    // 2. 即使放行，目录与文件走的是同一个命令 → Windows 上「定位文件」变成
    //    「用默认程序打开它」。
    //
    // 故这里钉住「按类型分流」与「不存在不 spawn」两个判据。
    Future<FileSystemEntityType> probeFile(String _) async =>
        FileSystemEntityType.file;
    Future<FileSystemEntityType> probeDir(String _) async =>
        FileSystemEntityType.directory;
    Future<FileSystemEntityType> probeMissing(String _) async =>
        FileSystemEntityType.notFound;

    test('文件 → 走定位（windows 上 /select,）', () async {
      final ok = await revealSystemEntry(
        r'C:\Users\me\a.md',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
        probe: probeFile,
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'explorer');
      expect(calls.single.$2, [r'/select,C:\Users\me\a.md']);
    });

    test('目录 → 走打开（windows 上 explorer <dir>，不带 /select）', () async {
      final ok = await revealSystemEntry(
        r'C:\Users\me\Downloads',
        platform: HostPlatform.windows,
        runner: fakeRunner(),
        probe: probeDir,
      );

      expect(ok, isTrue);
      expect(calls.single.$1, 'explorer');
      // 打开同步目录是 `explorer <dir>`；误用 `/select,` 会在父目录里选中它。
      expect(calls.single.$2, [r'C:\Users\me\Downloads']);
    });

    test('文件 → macos 用 open -R（不是 open）', () async {
      await revealSystemEntry(
        '/Users/me/a.md',
        platform: HostPlatform.macos,
        runner: fakeRunner(),
        probe: probeFile,
      );

      expect(calls.single.$1, 'open');
      expect(calls.single.$2, ['-R', '/Users/me/a.md']);
    });

    test('不存在 → false 且不 spawn（避免打开空路径）', () async {
      final ok = await revealSystemEntry(
        '/no/such/file.md',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
        probe: probeMissing,
      );

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('空路径 → false 且不 spawn', () async {
      final ok = await revealSystemEntry(
        '',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
        probe: probeFile,
      );

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('探测本身抛异常 → false，不向上抛', () async {
      Future<FileSystemEntityType> throwing(String _) async =>
          throw const FileSystemException('permission denied');

      final ok = await revealSystemEntry(
        '/root/secret.md',
        platform: HostPlatform.linux,
        runner: fakeRunner(),
        probe: throwing,
      );

      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('真实探测：临时目录 → 判为目录，临时文件 → 判为文件', () async {
      // 用真实 `realEntityType` 跑一遍，钉住「默认 probe 接的是 dart:io」
      // ——注入测试全用假 probe 的话，接线写反（比如把默认值指向一个恒返回
      // file 的函数）永远不会被发现。
      final dir = await Directory.systemTemp.createTemp('spb-reveal-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/a.md')..writeAsStringSync('x');

      expect(await realEntityType(dir.path), FileSystemEntityType.directory);
      expect(await realEntityType(file.path), FileSystemEntityType.file);
      expect(
        await realEntityType('${dir.path}/nope'),
        FileSystemEntityType.notFound,
      );
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

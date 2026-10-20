/// 系统「打开」命令的统一分派。
///
/// ## 为什么集中到本包
///
/// 「用系统默认程序打开某个目标」有**三个**调用场景，此前散在两处、且实现
/// 不一致：
///
/// | 场景 | 此前位置 | 覆盖平台 |
/// |---|---|---|
/// | 交付物同步目录 / 本地文件 | `apps/spb_desktop/lib/bootstrap.dart` 的 `_spawnSystemOpen` | Linux/macOS/Windows |
/// | OIDC 登录发起 | `apps/spb_desktop/lib/auth_browser.dart` 的 `openInBrowser` | **仅 Linux** |
/// | Markdown 回复里的链接 | 同上（`router.dart` 的 `onOpenLink`） | **仅 Linux** |
///
/// 后两处在 Windows/macOS 上抛 `PlatformError`，用户表现为「点了没反应」。
/// 根因不是「不想支持」，而是两条路径各自实现了一遍、其中一条忘了补分支。
/// 集中到本文件后只剩**一份**平台分支，新增平台只改这里。
///
/// ## 为什么不是简单的 `Process.run`
///
/// 用 [ProcessRunner] 注入而非直接调 `Process.run`：三平台的命令分派是
/// **纯逻辑**（哪个平台 spawn 哪个可执行文件、退出码怎么判），把它抽成可注入
/// 的形式就能在 Linux CI 上断言 macOS/Windows 分支——否则那两个分支要等到
/// 真机出问题才被发现（正是本次修复的缺口成因）。
///
/// ## 分层
///
/// 本文件只依赖 `dart:io` 与 `spb_core`，**不 import `package:flutter`**——
/// 与 `desktop_capabilities.dart` 同一取向（能力接口保持与 UI 框架无关）。
library;

import 'dart:io';

import 'package:spb_core/spb_core.dart';

/// 宿主平台。
///
/// ## 为什么不用 `dart:io` 的 `Platform` 直接判断
///
/// `Platform.isLinux` 等是**编译期常量**，无法在测试里切换，于是「macOS 分支
/// 是否正确」只能靠真机验证。抽出本枚举后，测试可以显式传 [HostPlatform.macos]
/// 并断言 spawn 了 `open`。
///
/// [other] 表示既非三大桌面平台（如 web、或将来新增的未知平台）——此时
/// **明确失败**而不是猜一个命令：静默什么都不做会让用户以为应用坏了。
enum HostPlatform {
  linux,
  macos,
  windows,
  other;

  /// 从 `dart:io` 的 [Platform] 推导当前平台。
  ///
  /// ## 这是本包唯一允许碰 `Platform` 的地方
  ///
  /// 其余代码一律接收 [HostPlatform] 参数。理由见枚举文档：`Platform.*` 是
  /// 编译期常量，散落使用会让「平台分派」变成不可测的逻辑。
  ///
  /// 判定顺序不能反：`isMacOS` / `isWindows` / `isLinux` 三者互斥，顺序无关，
  /// 但必须**先**判具体平台再回落 [other]——若先判 other 就永远是 other 了。
  static HostPlatform current() {
    if (Platform.isLinux) return HostPlatform.linux;
    if (Platform.isMacOS) return HostPlatform.macos;
    if (Platform.isWindows) return HostPlatform.windows;
    return HostPlatform.other;
  }
}

/// 进程执行器（可注入，便于在 Linux 上测三平台分支）。
abstract interface class ProcessRunner {
  /// 执行 [exe] 并等待结束。
  ///
  /// 实现方**不得**吞掉异常：由 [spawnSystemOpen] 统一接住并降级为 `false`，
  /// 这样「可执行文件不存在」与「命令返回非 0」在调用方看来是同一种结果
  /// （打不开），无需两套错误处理。
  Future<ProcessResult> run(String exe, List<String> args);
}

/// 真实实现：直接 spawn 系统进程。
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessResult> run(String exe, List<String> args) =>
      Process.run(exe, args);
}

/// 用系统默认程序打开 [target]（URL 或文件/目录路径）。
///
/// 返回 `true` 表示**已成功发起**（系统程序已启动，且退出码命中该平台的
/// 成功集合——Windows 的 `explorer` 成功也返回 1，见 [_successExitCodes]）；
/// `false` 表示平台不支持、可执行文件不存在或退出码不表示成功。
///
/// ## 为什么返回 bool 而不是抛异常
///
/// 与 [DesktopCapabilities] 的静默降级哲学一致（见
/// `desktop_capabilities.dart`）：调用方分两类——
/// - 交付物/文件打开：失败只在 UI 提示一次，不写 try/catch；
/// - OIDC 登录：失败要变成**用户可见的原因**（「无法打开浏览器，请手动访问…」）。
///
/// 后者在本函数之上包一层（把 `false` 翻成异常/文案），而不是让本函数对
/// 「谁调用」敏感。这样三平台分派与错误语义解耦。
///
/// ## 命令选择依据
///
/// | 平台 | 命令 | 说明 |
/// |---|---|---|
/// | Linux | `xdg-open` | freedesktop 标准，按目标类型（URL/文件/目录）自行分派 |
/// | macOS | `open` | 同上，系统级 |
/// | Windows | `explorer` | `explorer <target>` 会用默认程序打开；**不要**用 `start`——它是 `cmd.exe` 内建命令，不是可执行文件，`Process.run` 会找不到 |
///
/// ## 为什么 Windows 传 `explorer` 而不是 `rundll32`
///
/// `explorer` 对 URL 与文件路径都能工作，且不需要拼 shell 引号（`Process.run`
/// 不经过 shell，参数按数组传递，路径里的空格/引号不会被解释）。`start` 必须
/// 经 `cmd /c`，多一层 shell 就多一层注入面。
///
/// ## ⚠️ Windows 的「成功」退出码是 0 **或 1**
///
/// 见 [_successExitCodes]：`explorer <target>` 委托给已运行的 shell / 默认
/// 浏览器后自己立刻退出，**成功也返回 1**。按「非 0 即失败」判定会让每一次
/// 成功的打开都被判成失败——Windows 上表现为登录时弹「无法打开浏览器，请手动
/// 访问…」（浏览器其实已经打开了）、以及「打开文件 / 打开同步目录」点了没反应。
Future<bool> spawnSystemOpen(
  String target, {
  required HostPlatform platform,
  required ProcessRunner runner,
}) async {
  // 空目标不 spawn：某些平台会把空参数当成「打开当前目录/主目录」，
  // 用户会看到一个莫名其妙的窗口。
  if (target.isEmpty) {
    SpbLog.warn('spawnSystemOpen 目标为空，跳过', {'platform': platform.name});
    return false;
  }

  final String exe;
  switch (platform) {
    case HostPlatform.linux:
      exe = 'xdg-open';
    case HostPlatform.macos:
      exe = 'open';
    case HostPlatform.windows:
      exe = 'explorer';
    case HostPlatform.other:
      SpbLog.warn('当前平台不支持打开目标', {'target': target, 'platform': platform.name});
      return false;
  }

  try {
    final result = await runner.run(exe, [target]);
    if (!_successExitCodes(platform).contains(result.exitCode)) {
      SpbLog.warn('系统打开命令返回非成功退出码', {
        'exe': exe,
        'target': target,
        'exit': result.exitCode,
        'platform': platform.name,
      });
      return false;
    }
    return true;
  } on Object catch (e) {
    // 含 ProcessException（可执行文件不存在，如无桌面的 Linux 容器里没有
    // xdg-open）。这是**预期内**的降级路径，故用 warn 而非 error。
    SpbLog.warn('系统打开命令 spawn 异常', {
      'exe': exe,
      'target': target,
      'error': '$e',
    });
    return false;
  }
}

/// 该平台视为「已成功发起」的退出码集合。
///
/// ## 为什么 Windows 要额外接受 1
///
/// `explorer.exe` 不是「打开某个东西」的工具，而是**shell 本身**：收到参数时
/// 它把请求转交给已运行的 explorer 实例 / 默认浏览器，然后**自己立即退出**，
/// 退出码与「目标是否真的被打开」无关。实测与上游一致：`explorer.exe https://…`
/// 会打开浏览器，但退出码是 **1**（microsoft/WSL#6565 —— *"The process exits
/// with 1 and opens the GitHub website"*，维护者确认「退出码 1 是 Windows 应用
/// 的常态，控制台程序成功才返回 0」）。
///
/// 于是「非 0 即失败」在 Windows 上等于「永远失败」：浏览器打开了，客户端却
/// 报「无法打开浏览器」并放弃等待 loopback 回调（`auth_loopback.dart`）。
///
/// ## 接受 1 的代价（诚实记录）
///
/// `explorer` 返回 1 时我们**无法区分**「已交给默认程序」与「目标不存在 / 协议
/// 未注册」。这是可接受的：
///
/// - 「打开文件 / 打开目录」两条调用链在 spawn 之前**已经探测过路径存在**
///   （`bootstrap.dart` 的 `revealPath` / `openFile`），可靠性不依赖退出码；
/// - 对 URL 而言，误报「成功」的后果是「浏览器没开、登录页停在等待回调」，
///   而误报「失败」的后果是**每次登录都失败**——后者确定发生、前者只在
///   `http(s)` 协议未注册这类罕见环境下发生。
///
/// ⚠️ **不要把这条放宽到其他平台**：`xdg-open` / `open` 有正常的退出码语义，
/// 把 1 也算成功会掩盖「没有默认浏览器」等真实故障（有用例钉住）。
Set<int> _successExitCodes(HostPlatform platform) => switch (platform) {
  HostPlatform.windows => const {0, 1},
  HostPlatform.linux || HostPlatform.macos || HostPlatform.other => const {0},
};

/// 便捷入口：用当前平台与真实进程执行器打开 [target]。
///
/// 生产代码用本函数（不必自己传 [HostPlatform.current] 与
/// [SystemProcessRunner]）；测试用 [spawnSystemOpen] 显式注入。
Future<bool> spawnSystemOpenHere(String target) => spawnSystemOpen(
  target,
  platform: HostPlatform.current(),
  runner: const SystemProcessRunner(),
);

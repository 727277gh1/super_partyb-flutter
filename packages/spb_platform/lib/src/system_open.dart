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
/// 返回 `true` 表示**已成功发起**（系统程序已启动且退出码为 0）；`false` 表示
/// 平台不支持、可执行文件不存在或返回非 0。
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
    if (result.exitCode != 0) {
      SpbLog.warn('系统打开命令返回非 0', {
        'exe': exe,
        'target': target,
        'exit': result.exitCode,
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

/// 便捷入口：用当前平台与真实进程执行器打开 [target]。
///
/// 生产代码用本函数（不必自己传 [HostPlatform.current] 与
/// [SystemProcessRunner]）；测试用 [spawnSystemOpen] 显式注入。
Future<bool> spawnSystemOpenHere(String target) => spawnSystemOpen(
  target,
  platform: HostPlatform.current(),
  runner: const SystemProcessRunner(),
);

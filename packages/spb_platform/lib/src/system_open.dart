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
/// ## 平台内还要按**目标形态**分派（Windows）
///
/// 「哪个平台 spawn 哪个命令」不足以描述 Windows：URL 与文件/目录路径要用
/// **不同**的命令（`rundll32` vs `explorer`），见 [looksLikeUrl] 与
/// [spawnSystemOpen] 的文档——用 `explorer` 打开带 query string 的 URL 会得到
/// 一个文件浏览器窗口，而 OIDC 授权 URL 必然带 query string。
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
/// 返回 `true` 表示**已成功发起**（系统程序已启动；在退出码有意义的路径上
/// 还要求它命中该平台的成功集合，见 [_successExitCodes] 与
/// [looksLikeUrl] 的说明）；`false` 表示平台不支持、可执行文件不存在或退出码
/// 不表示成功。
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
/// | 平台 | 目标 | 命令 | 说明 |
/// |---|---|---|---|
/// | Linux | 任意 | `xdg-open` | freedesktop 标准，按目标类型（URL/文件/目录）自行分派 |
/// | macOS | 任意 | `open` | 同上，系统级 |
/// | Windows | URL（含 `://`） | `rundll32 url.dll,FileProtocolHandler` | **不能用 `explorer`**，见下 |
/// | Windows | 文件/目录路径 | `explorer` | 在资源管理器里定位/用默认程序打开 |
///
/// 三平台都**不要**用 `start`：它是 `cmd.exe` 内建命令，不是可执行文件，
/// `Process.run` 找不到；经 `cmd /c` 又会被重新解析一遍命令行，URL 里的 `&`
/// 会变成命令分隔符（注入面）。
///
/// ## ⚠️ 为什么 Windows 上 URL 必须走 `rundll32` 而不是 `explorer`
///
/// 这是**踩过的真实缺陷**：SSO 登录每次都会打开一个**文件浏览器窗口**而不是
/// 浏览器。`explorer.exe <url>` 只在 URL **不带 query string** 时才委托给默认
/// 浏览器；一旦带 `?a=1&b=2`，它会把参数当成路径去浏览（实测与上游一致：
/// microsoft/WSL#3832 *"Actual result: Generic file explorer window opens"*、
/// dotnet/runtime#108817 *"Process.Start opens explorer itself instead of URL"*）。
///
/// 而 OIDC 授权 URL **必然**带 query string（`response_type` / `client_id` /
/// `redirect_uri` / `scope` / `state` / `nonce` / `code_challenge` /
/// `code_challenge_method`，见 `OidcPkce.buildAuthorizeUrl`），故每次登录都命中。
/// 后果不是「报错」，而是**更糟的静默失败**：文件浏览器开了、退出码仍算成功，
/// 客户端继续等 loopback 回调，用户看到的是「点了没反应」+ 一个莫名的窗口。
///
/// `rundll32 url.dll,FileProtocolHandler <url>` 是 Windows 上按 URL 协议分派
/// 给默认处理程序的正确入口，query string 原样保留。
///
/// ## ⚠️ Windows 文件/目录的「成功」退出码是 0 **或 1**
///
/// 见 [_successExitCodes]：`explorer <target>` 委托给已运行的 shell 后自己立刻
/// 退出，**成功也返回 1**（microsoft/WSL#6565）。按「非 0 即失败」判定会让
/// 每一次成功的打开都被判成失败——Windows 上表现为「打开文件 / 打开同步目录」
/// 点了没反应。
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
  final List<String> args;
  // `rundll32` 的退出码恒为 0（见 [_successExitCodes]），故该分支不据退出码
  // 判定成败——判了也恒为「成功」，只是把「无法判定」伪装成「已判定」。
  var exitCodeIsMeaningful = true;
  switch (platform) {
    case HostPlatform.linux:
      exe = 'xdg-open';
      args = [target];
    case HostPlatform.macos:
      exe = 'open';
      args = [target];
    case HostPlatform.windows when looksLikeUrl(target):
      // URL 走 rundll32：`explorer <带 query 的 URL>` 会打开文件浏览器。
      exe = 'rundll32';
      args = ['url.dll,FileProtocolHandler', target];
      exitCodeIsMeaningful = false;
    case HostPlatform.windows:
      exe = 'explorer';
      args = [target];
    case HostPlatform.other:
      SpbLog.warn('当前平台不支持打开目标', {'target': target, 'platform': platform.name});
      return false;
  }

  try {
    final result = await runner.run(exe, args);
    if (exitCodeIsMeaningful &&
        !_successExitCodes(platform).contains(result.exitCode)) {
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

/// 在系统文件管理器中**定位**（选中）[path] 这个文件或目录。
///
/// 与 [spawnSystemOpen] 的区别是**意图**：后者是「用默认程序打开它」
/// （`.md` 交给编辑器、目录交给文件管理器），本函数是「在文件管理器里
/// 把我带到它面前并选中」。`DesktopCapabilities.revealPath` 走的是本函数。
///
/// ## ⚠️ 这是「定位」在 Windows 上恒失败的真实缺陷的修法
///
/// 修复前 `revealPath` 只 spawn `explorer <路径>`——那是**用默认程序打开**，
/// 不是定位。用户点「在文件管理器中定位」时，Windows 会把文件交给 Word/
/// 编辑器打开，而**不会**在资源管理器里选中它；对某些扩展名（或无关联的
/// 文件）则什么都不发生。三个平台各需要不同的参数形态：
///
/// | 平台 | 命令 | 说明 |
/// |---|---|---|
/// | Windows | `explorer /select,<path>` | `/select,` 与路径**必须是同一个参数**（见下） |
/// | macOS | `open -R <path>` | `-R` = reveal in Finder |
/// | Linux | `xdg-open <父目录>` | freedesktop **没有**「选中某个文件」的概念 |
///
/// ## Linux 为什么只能打开父目录（诚实记录）
///
/// `xdg-open` 只接受「要打开的目标」，没有 `--select`。要真正选中需要
/// D-Bus 调 `org.freedesktop.FileManager1.ShowItems`（依赖文件管理器实现该
/// 接口），或按 `xdg-mime query default inode/directory` 分派到 nautilus/
/// dolphin/thunar 各自的命令行（`nautilus --select` / `dolphin --select`…），
/// 两条都脆弱。打开父目录已能满足「我要找这个文件在哪」的诉求。
///
/// ## ⚠️ Windows 的 `/select,` 必须与路径**拼成一个参数**
///
/// `explorer` 的参数解析不走标准 CRT：写成两个参数（`['/select,', path]`）时
/// 它把 `/select,` 当成「要打开的路径」，行为不可预测。实测与上游一致：
/// `explorer.exe /select,"C:\path\file.txt"` 是唯一正确形态。
///
/// 路径含空格时**不加引号**：`Process.run` 按数组传参、不经 shell，Windows 侧
/// 会自己处理参数边界；加引号反而会让引号成为路径的一部分。
///
/// 退出码语义与 [spawnSystemOpen] 的 Windows 分支一致（`explorer` 成功也返回
/// 1，见 [_successExitCodes]）。
Future<bool> spawnSystemReveal(
  String path, {
  required HostPlatform platform,
  required ProcessRunner runner,
}) async {
  if (path.isEmpty) {
    SpbLog.warn('spawnSystemReveal 目标为空，跳过', {'platform': platform.name});
    return false;
  }

  final String exe;
  final List<String> args;
  switch (platform) {
    case HostPlatform.linux:
      // 没有「选中条目」的概念：退化为打开所在目录。
      final parent = _parentOf(path);
      if (parent == null) {
        SpbLog.warn('无法推导父目录，跳过定位', {'path': path});
        return false;
      }
      exe = 'xdg-open';
      args = [parent];
    case HostPlatform.macos:
      exe = 'open';
      args = ['-R', path];
    case HostPlatform.windows:
      exe = 'explorer';
      // 单个参数：`/select,` 与路径之间**不能**有空格分隔成两个 argv。
      args = ['/select,$path'];
    case HostPlatform.other:
      SpbLog.warn('当前平台不支持定位条目', {'target': path, 'platform': platform.name});
      return false;
  }

  try {
    final result = await runner.run(exe, args);
    if (!_successExitCodes(platform).contains(result.exitCode)) {
      SpbLog.warn('系统定位命令返回非成功退出码', {
        'exe': exe,
        'target': path,
        'exit': result.exitCode,
        'platform': platform.name,
      });
      return false;
    }
    return true;
  } on Object catch (e) {
    SpbLog.warn('系统定位命令 spawn 异常', {'exe': exe, 'target': path, 'error': '$e'});
    return false;
  }
}

/// 探测路径类型（可注入，便于在 Linux 上断言「文件 → 定位 / 目录 → 打开」）。
typedef EntityTypeProbe = Future<FileSystemEntityType> Function(String path);

/// 真实探测：直接问 `dart:io`。
Future<FileSystemEntityType> realEntityType(String path) =>
    FileSystemEntity.type(path);

/// 「定位一个本地条目」的完整语义：**目录就打开它，文件就选中它**。
///
/// `DesktopCapabilities.revealPath` 的真实实现就是本函数（经 `bootstrap.dart`
/// 一行转发）。把它放在本包而不是 `bootstrap.dart`，是为了让「按类型分流 +
/// 存在性校验」这段**正确性核心**能在无桌面环境的 CI 里逐条断言——
/// `bootstrap.dart` 依赖 window_manager 等插件，测试里构造不起来。
///
/// ## ⚠️ 它修的是一个「三平台全不工作」的真实缺陷
///
/// 修复前的实现只接受目录：用 `Directory(path).exists()` 校验，而对**文件**
/// 恒为 false（实测）。于是时间线卡片与交付物面板的「在文件管理器中定位」
/// 传文件路径时，在 spawn **之前**就返回 false 了——用户看到「无法定位文件」。
///
/// ## 为什么要分两种命令
///
/// | 目标 | 命令 | 语义 |
/// |---|---|---|
/// | 目录 | `spawnSystemOpen` | 在文件管理器里打开它 |
/// | 文件 | `spawnSystemReveal` | 在文件管理器里**选中**它 |
///
/// 在 Windows 上前者是 `explorer <dir>`、后者是 `explorer /select,<file>`。
/// 把文件交给 `explorer <file>` 会用默认程序**打开它**（Word/编辑器弹出来）
/// ——那正是修复前「定位」的第二个缺陷。
Future<bool> revealSystemEntry(
  String path, {
  required HostPlatform platform,
  required ProcessRunner runner,
  EntityTypeProbe probe = realEntityType,
}) async {
  if (path.isEmpty) {
    SpbLog.warn('revealSystemEntry 目标为空，跳过', {'platform': platform.name});
    return false;
  }

  final FileSystemEntityType type;
  try {
    type = await probe(path);
  } on Object catch (e) {
    // 权限不足 / 路径含非法字符等：记日志后静默降级（与 [spawnSystemOpen]
    // 的 spawn 异常同一取向），不向上抛。
    SpbLog.warn('revealSystemEntry 探测目标失败', {'path': path, 'error': '$e'});
    return false;
  }

  if (type == FileSystemEntityType.notFound) {
    // 不存在就不 spawn：启动一个打开空路径的文件管理器只会让用户以为
    // 应用坏了（对齐 `openFile` 的校验取向）。
    SpbLog.warn('revealSystemEntry 目标不存在', {'path': path});
    return false;
  }

  return type == FileSystemEntityType.directory
      ? spawnSystemOpen(path, platform: platform, runner: runner)
      : spawnSystemReveal(path, platform: platform, runner: runner);
}

/// 便捷入口：用当前平台与真实进程执行器定位条目。
Future<bool> revealSystemEntryHere(String path) => revealSystemEntry(
  path,
  platform: HostPlatform.current(),
  runner: const SystemProcessRunner(),
);

/// 取 [path] 的父目录（去掉末尾分隔符后再退一级）；已是根或无分隔符时返回 null。
///
/// 只用于 Linux 的定位降级（打开所在目录）。用 `package:path` 的 `dirname`
/// 会引入本包当前没有的依赖，而这里只需处理 `/` 与 `\` 两种分隔符。
String? _parentOf(String path) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == '/' || path[end - 1] == '\\')) {
    end--;
  }
  if (end == 0) return null;
  final trimmed = path.substring(0, end);
  final idx = trimmed.lastIndexOf(RegExp(r'[/\\]'));
  if (idx <= 0) return null;
  return trimmed.substring(0, idx);
}

/// [target] 是否是**带 scheme 的 URL**（而非文件/目录路径）。
///
/// 只用于 Windows 的命令分派（URL → `rundll32`，路径 → `explorer`）。
///
/// ## 为什么用正则而不是 `Uri.parse(target).scheme`
///
/// `Uri.parse` 会把 Windows 路径解析出 scheme：实测 `C:\Users\me\file.md`
/// 得到 `scheme=c`、`path=/Users/me/file.md`。据此判定会让**每一个** Windows
/// 文件路径都走 URL 分支（交给 `rundll32`），比原缺陷更难查。
///
/// 故只认 `scheme://` 形态（`file://` / `https://` / 自定义 scheme 都命中；
/// `C:\` 与 `C:/` 都不命中——前者是 `:\`，后者只有单个 `/`）。
bool looksLikeUrl(String target) =>
    RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(target);

/// 该平台视为「已成功发起」的退出码集合。
///
/// ## 为什么 Windows 要额外接受 1
///
/// `explorer.exe` 不是「打开某个东西」的工具，而是**shell 本身**：收到参数时
/// 它把请求转交给已运行的 explorer 实例，然后**自己立即退出**，退出码与
/// 「目标是否真的被打开」无关。实测与上游一致：`explorer.exe <路径>` 打开了
/// 目标，但退出码是 **1**（microsoft/WSL#6565 —— *"The process exits with 1
/// and opens the GitHub website"*，维护者确认「退出码 1 是 Windows 应用的常态，
/// 控制台程序成功才返回 0」）。
///
/// 于是「非 0 即失败」在 Windows 上等于「永远失败」：目录打开了，客户端却报
/// 失败，用户表现为「点了没反应」。
///
/// ## 接受 1 的代价（诚实记录）
///
/// `explorer` 返回 1 时我们**无法区分**「已交给默认程序」与「目标不存在」。
/// 这是可接受的：「打开文件 / 打开目录」两条调用链在 spawn 之前**已经探测过
/// 路径存在**（`bootstrap.dart` 的 `revealPath` / `openFile`），可靠性不依赖
/// 退出码。
///
/// ## ⚠️ `rundll32` 分支**不看**退出码
///
/// 它的退出码恒为 0（上游确认：*"rundll32 does not give you any return value,
/// its exit code is always zero"*），即「URL 没打开」与「打开了」在退出码上
/// 完全同形。故 URL 分支退化为「spawn 成功即视为已发起」——`spawnSystemOpen`
/// 里用 `exitCodeIsMeaningful = false` 显式跳过判定，而不是假装 0 能说明什么。
/// 代价：Windows 上 URL 打不开时不再有即时错误，而是由上层超时兜底
/// （`auth_loopback.dart` 的 5 分钟 + 登录页的「手动访问 URL / 粘贴导入」降级
/// 路径）。这与「误报失败导致每次登录都失败」相比仍是更好的取舍。
///
/// ⚠️ **不要把 `{0,1}` 放宽到其他平台**：`xdg-open` / `open` 有正常的退出码
/// 语义，把 1 也算成功会掩盖「没有默认浏览器」等真实故障（有用例钉住）。
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

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:spb_core/spb_core.dart';

import 'desktop_capabilities.dart';

/// 把诊断报告写入用户选定的文件（issue #40）。
///
/// ## 为什么单独一个类，而不是塞进 `bootstrap.dart` 的能力实现
///
/// 与 [FileSelectorDirectoryPicker] 同一理由：本类只做「弹保存对话框 + 写
/// 文件」这一件事，且两处失败点（对话框打不开、目录不可写）都需要被单测
/// 覆盖。抽出来后可注入 [pickSavePath] / [writeText]，于是无需 GUI、无需
/// 真实磁盘就能断言三态结果。
///
/// ## 为什么是「另存为」而不是「写进某个固定目录」
///
/// 报告是给用户**附给报障**用的，必须落到用户能找到的地方。固定目录
/// （如应用数据目录）在 macOS 沙箱与 Linux 上都是隐藏路径，用户根本找不着
/// ——「导出成功但用户拿不到文件」比导出失败更糟。
///
/// ## 为什么不用剪贴板
///
/// 报告可能有上千行（最多 500 条日志），粘进聊天窗口会被截断；且剪贴板是
/// **静默**的（用户不知道复制成功没有）。保存成文件能看见路径与大小。
///
/// ⚠️ **本类只在桌面端被接线**（`PlatformDesktopCapabilities.saveDiagnostics`）。
/// 移动端注入 `NoopDesktopCapabilities`，在到达本类之前就返回
/// [DiagnosticsExportOutcome.unsupported]——因为 `file_selector` 的
/// `getSaveLocation` 在 Android/iOS 上**未实现**（基类抛
/// `UnimplementedError`）。移动端要做需引入 `share_plus`，属独立一轮
/// （同 AGENTS.md §6.9.1「移动端打开已下载文件」的取舍）。
class DiagnosticsExporter {
  const DiagnosticsExporter({this.pickSavePath, this.writeText});

  /// 弹出「另存为」对话框，返回用户选定的路径；null = 取消。
  ///
  /// 默认实现走 `file_selector` 的 [getSaveLocation]。注入点存在的意义是
  /// 测试：`flutter test` 里没有平台通道，默认实现会抛
  /// `MissingPluginException`。
  final Future<String?> Function({required String suggestedName})? pickSavePath;

  /// 把 [text] 写入 [path]。
  ///
  /// 默认实现用 [File.writeAsString] 且 `flush: true`——报告是要立刻交给
  /// 用户的，不能留在 OS 写缓存里等着「稍后落盘」。
  final Future<void> Function(String path, String text)? writeText;

  /// 导出 [text]。
  ///
  /// 返回三态见 [DiagnosticsExportOutcome]：**取消不是失败**，调用方据此
  /// 决定要不要弹提示。
  Future<DiagnosticsExportOutcome> save(
    String text, {
    required String suggestedName,
  }) async {
    String? path;
    try {
      path = await (pickSavePath ?? _pickSavePath)(
        suggestedName: suggestedName,
      );
    } on Object catch (e) {
      // 平台没有「另存为」（如移动端的 getSaveLocation 未实现）、或没有 GUI。
      SpbLog.warn('打开诊断报告保存对话框失败', {'error': '$e'});
      return DiagnosticsExportOutcome.failed;
    }

    // 空串等同于取消：Linux 的 GTK 实现偶尔会这样返回（同
    // `FileSelectorDirectoryPicker.pick` 的处理）。
    if (path == null || path.isEmpty) {
      return DiagnosticsExportOutcome.cancelled;
    }

    try {
      await (writeText ?? _writeText)(path, text);
    } on Object catch (e) {
      // 目录不可写 / 磁盘满 / 路径被占用：都是预期内的降级路径，不抛异常。
      SpbLog.warn('写入诊断报告失败', {'error': '$e'});
      return DiagnosticsExportOutcome.failed;
    }

    SpbLog.info('诊断报告已导出', {'bytes': text.length});
    return DiagnosticsExportOutcome.saved;
  }

  /// 默认的「另存为」实现。
  ///
  /// 扩展名过滤写成 `.txt`：报告是纯文本，让用户在对话框里看到「文本文件」
  /// 比「所有文件」更不容易存错。部分平台（如 macOS）会忽略过滤器，这是
  /// 已知且无害的——[suggestedName] 里已经带了 `.txt`。
  static Future<String?> _pickSavePath({required String suggestedName}) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: '文本文件', extensions: ['txt']),
      ],
      suggestedName: suggestedName,
      confirmButtonText: '导出',
    );
    return location?.path;
  }

  /// 默认的写文件实现。
  static Future<void> _writeText(String path, String text) =>
      File(path).writeAsString(text, flush: true);
}

/// 采集诊断报告要附的**非机密**运行环境信息。
///
/// ## 为什么在这里采集（而不是在 `spb_core`）
///
/// `spb_core` 是纯 Dart 包（分层规则禁止 import `package:flutter/*`），拿不到
/// [appBuildName] / [FlutterVersion] 这类 Flutter 侧编译期常量。本包有 Flutter
/// 依赖，是采集这些值的最低层。
///
/// ## 为什么这些键可以进报告（逐条依据）
///
/// 报告会被用户贴进公开 issue，故每个值都必须是**公开**的：
///
/// | 键 | 是否机密 | 依据 |
/// |---|---|---|
/// | `app` / `build` / `flutter` / `dart` / `channel` | 否 | 版本号 |
/// | `platform` / `os` | 否 | 平台名与内核版本（`Platform.operatingSystemVersion`） |
/// | `env` | 否 | `dev`/`staging`/`prod` 短名 |
/// | `api` / `ufs` / `oidc_issuer` | 否 | 服务地址。`env.dart` 已说明发布包的地址由 CI Variables 注入，而 Variables 在公开仓库里**本来就是公开的** |
/// | `endpoint_host` / `endpoint_probe` | 否 | 启动探测选中的**主机名**与状态短名（`upgraded`/`kept`/`skipped`）。主机名与同组的 `api`/`ufs` 同源（就是它们 host 部分的副本），不含路径/查询串/凭证 |
/// | `oidc_client_id` | 否 | `env.dart` 明写「client_id 是公开值（会出现在授权 URL 里）」 |
/// | `verbose_log` / `release` | 否 | 布尔开关 |
///
/// **没有**任何 token / secret / 凭证进这个 Map——日志侧同理（见
/// `spb_api` 的 `session_credential.dart`：「本函数绝不记录 token 值」）。
/// 即便如此，[buildDiagnosticsReport] 仍会整体过一遍 [redactSecrets]。
///
/// ## 为什么键名用 snake_case
///
/// 与 Go API 的 slog 字段约定（`request_id` / `group_id`）一致，便于报障时
/// 人工比对两侧日志。
Map<String, String> diagnosticsEnvironment() {
  return <String, String>{
    // `?? '未知'`：`appBuildName` 在 pubspec 无 `version` 且未传
    // `--build-name` 时为 null（见 flutter 的 `app_version.dart`）。
    // 用「未知」而不是空串——空串在报告里看起来像「这一行没生成出来」。
    'app': appBuildName ?? '未知',
    'build': appBuildNumber ?? '未知',
    'flutter': FlutterVersion.version ?? '未知',
    'channel': FlutterVersion.channel ?? '未知',
    'dart': FlutterVersion.dartVersion ?? '未知',
    'framework_revision': FlutterVersion.frameworkRevision ?? '未知',
    'engine_revision': FlutterVersion.engineRevision ?? '未知',
    'platform': SpbEnv.platformName,
    'os': Platform.operatingSystemVersion,
    'env': SpbEnv.environment,
    'api': SpbEndpoints.current.apiBaseUrl,
    'ufs': SpbEndpoints.current.ufsBaseUrl,
    // 端点选择的**结论**。只记 host 名与状态短名（非完整 URL）：
    // 报告要回答的是「客户端到底连的哪个域名」，而完整 URL 里的路径与
    // 查询串对排障无意义、却可能含用户标识。
    //
    // `chosenHost` 为 null 只出现在「未调用启动探测」的路径（如单元测试、
    // 或 SPB_PREFERRED_HOSTS 留空 → `skipped`）——写「(未探测)」而不是空串，
    // 否则报告里看起来像「这一行没生成出来」。
    'endpoint_host': SpbEndpoints.current.chosenHost ?? '(未探测)',
    'endpoint_probe': SpbEndpoints.current.probeOutcome.name,
    // 运行中升降级的实时状态（issue #50）。与 `endpoint_probe` 配合才能
    // 回答「为什么用户连的是 CDN」：
    //   outcome=downgraded + 有挂起重探 → 正在等冷却期，会自己恢复；
    //   outcome=downgraded + 无挂起重探 → 恢复循环断了（真正的异常）。
    // 只记整数与布尔，不记 host 以外的地址信息。
    'endpoint_consecutive_failures': EndpointGuard.instance.consecutiveFailures
        .toString(),
    'endpoint_upgrade_pending': EndpointGuard.instance.hasPendingUpgrade
        .toString(),
    'oidc_issuer': SpbEnv.oidcIssuer,
    'oidc_client_id': SpbEnv.oidcClientId.isEmpty
        ? '（未配置）'
        : SpbEnv.oidcClientId,
    'verbose_log': SpbEnv.verboseLogging.toString(),
    'release': SpbEnv.isRelease.toString(),
  };
}

/// 组装诊断报告并交给平台保存（**两端装配层的唯一入口**）。
///
/// ## 为什么要有这个「一步到位」的函数
///
/// 报告文本、环境信息、文件名规则三者必须两端一致。若让两端 router 各自
/// 拼一遍，就会出现本仓库最常见的失败模式——一端改了、另一端没改，而测试
/// 全绿（见 AGENTS.md §6.17 的接线守卫为何存在）。故装配层只写一行：
///
/// ```dart
/// onExportDiagnostics: () => exportDiagnosticsReport(caps),
/// ```
///
/// [now] 只供测试固定时间戳（文件名与报告头都用到它）。
Future<DiagnosticsExportOutcome> exportDiagnosticsReport(
  DesktopCapabilities capabilities, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final text = buildDiagnosticsReport(
    environment: diagnosticsEnvironment(),
    generatedAt: at,
  );
  return capabilities.saveDiagnostics(
    text,
    suggestedName: 'spb-diagnostics-${_fileNameStamp(at)}.txt',
  );
}

/// 文件名时间戳：`20261012-203045`。
///
/// 用「日期-时刻」而不是 ISO8601：ISO 里含 `:`，而 `:` 在 Windows 文件名里
/// 是**非法字符**（NTFS 用它作数据流分隔符），`File.writeAsString` 会失败。
/// 这也是「导出在 Linux 上正常、Windows 用户报错」的经典成因。
String _fileNameStamp(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}${two(at.second)}';
}

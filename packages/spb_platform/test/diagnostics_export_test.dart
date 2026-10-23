import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// `DiagnosticsExporter` 与诊断报告装配（issue #40）。
///
/// ## 这个测试防的是什么
///
/// 「导出诊断日志」是用户报障时**唯一**的信息来源，而它的失败模式都是
/// **静默**的：
/// - 把「用户取消」当失败 → 用户点一下取消就看到「导出失败」，以为功能坏了；
/// - 把「失败」当成功 → 弹「已导出」但磁盘上什么都没有，用户白找一场；
/// - 文件名带 `:`（ISO8601 时间戳的副产物）→ **Linux 上正常、Windows 上报错**
///   （`:` 是 NTFS 的非法文件名字符），而 CI 只跑 Linux；
/// - 环境信息里混进凭证 → 报告会被贴进公开 issue，泄漏无法收回。
///
/// 故这里对四态、文件名形态、以及「环境信息不含任何机密」逐条断言。
void main() {
  // 静音：本文件会故意触发多条 warn 日志（对话框抛异常、写文件失败），
  // 而 `ConsoleLogSink` 会把它们打进测试输出，淹没断言失败信息。
  setUp(
    () => SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug),
  );
  tearDown(SpbLog.clearRecentLogs);

  group('DiagnosticsExporter.save：四态', () {
    test('写入成功 → saved', () async {
      final written = <String, String>{};
      final exporter = DiagnosticsExporter(
        pickSavePath: ({required suggestedName}) async => '/tmp/$suggestedName',
        writeText: (path, text) async => written[path] = text,
      );

      final outcome = await exporter.save(
        '报告正文',
        suggestedName: 'spb-diagnostics.txt',
      );

      expect(outcome, DiagnosticsExportOutcome.saved);
      expect(written, {'/tmp/spb-diagnostics.txt': '报告正文'});
    });

    test('用户取消（null）→ cancelled，且**不**写文件', () async {
      var wrote = false;
      final exporter = DiagnosticsExporter(
        pickSavePath: ({required suggestedName}) async => null,
        writeText: (path, text) async => wrote = true,
      );

      expect(
        await exporter.save('x', suggestedName: 'n.txt'),
        DiagnosticsExportOutcome.cancelled,
      );
      expect(wrote, isFalse, reason: '取消不是失败，但也不该写任何东西');
    });

    test('对话框返回空串（GTK 偶尔这样）也当取消', () async {
      // 与 `FileSelectorDirectoryPicker.pick` 同一处理：空串不是合法路径，
      // 若当成成功会去写「当前目录下一个空名字文件」。
      var wrote = false;
      final exporter = DiagnosticsExporter(
        pickSavePath: ({required suggestedName}) async => '',
        writeText: (path, text) async => wrote = true,
      );

      expect(
        await exporter.save('x', suggestedName: 'n.txt'),
        DiagnosticsExportOutcome.cancelled,
      );
      expect(wrote, isFalse);
    });

    test('对话框抛异常（无 GUI / 平台未实现）→ failed，不抛给调用方', () async {
      final exporter = DiagnosticsExporter(
        pickSavePath: ({required suggestedName}) async =>
            throw UnimplementedError('getSaveLocation'),
      );

      // 关键：不抛。设置页不该为「无 DISPLAY」写 try/catch。
      expect(
        await exporter.save('x', suggestedName: 'n.txt'),
        DiagnosticsExportOutcome.failed,
      );
    });

    test('写文件抛异常（目录只读 / 磁盘满）→ failed，不抛给调用方', () async {
      final exporter = DiagnosticsExporter(
        pickSavePath: ({required suggestedName}) async => '/tmp/x.txt',
        writeText: (path, text) async =>
            throw const FileSystemException('Permission denied'),
      );

      expect(
        await exporter.save('x', suggestedName: 'n.txt'),
        DiagnosticsExportOutcome.failed,
      );
    });
  });

  group('exportDiagnosticsReport：文件名与环境信息', () {
    test('文件名是平台安全的（**不含** `:`，Windows 非法）', () async {
      // ## 这个用例防的是一次真实的平台特异性缺陷
      //
      // 直觉写法是 `DateTime.now().toIso8601String()`，它含 `:`。而 `:` 在
      // NTFS 上是数据流分隔符，`File.writeAsString` 会失败——表现为
      // 「Linux 开发机一切正常，Windows 用户报导出失败」。
      String? name;
      final caps = _RecordingCapabilities(
        onSave: (text, suggestedName) => name = suggestedName,
      );

      await exportDiagnosticsReport(
        caps,
        now: DateTime(2026, 10, 12, 20, 30, 45),
      );

      expect(name, isNotNull);
      expect(name, isNot(contains(':')));
      expect(name, contains('20261012-203045'));
      expect(name, endsWith('.txt'));
    });

    test('文件名只含文件名安全字符（可被各平台直接落盘）', () async {
      String? name;
      final caps = _RecordingCapabilities(
        onSave: (text, suggestedName) => name = suggestedName,
      );

      await exportDiagnosticsReport(caps, now: DateTime(2026, 1, 2, 3, 4, 5));

      // Windows 非法字符集合：< > : " / \ | ? *
      for (final ch in ['<', '>', ':', '"', '/', r'\', '|', '?', '*']) {
        expect(name, isNot(contains(ch)), reason: '文件名不得含 `$ch`');
      }
    });

    test('报告文本经 capabilities.saveDiagnostics 传出（不经剪贴板等旁路）', () async {
      String? captured;
      final caps = _RecordingCapabilities(
        onSave: (text, suggestedName) => captured = text,
      );

      await exportDiagnosticsReport(caps);

      expect(captured, isNotNull);
      expect(captured, contains('Super PartyB 诊断报告'));
      expect(captured, contains('## 运行环境'));
      expect(captured, contains('## 最近日志'));
    });

    test('环境信息含版本 / 平台 / 服务地址等非机密字段', () {
      final env = diagnosticsEnvironment();

      // 逐条依据见 `diagnosticsEnvironment` 的文档（每个值都是公开的）。
      expect(env['app'], isNotNull);
      expect(env['flutter'], isNotNull);
      expect(env['dart'], isNotNull);
      expect(env['platform'], isNotNull);
      expect(env['env'], isNotNull);
      expect(env['api'], isNotNull);
      expect(env['ufs'], isNotNull);
      expect(env['oidc_issuer'], isNotNull);
      // 编译期常量为空时写「未知」而不是空串（空串看起来像「没生成出来」）。
      expect(env['app'], isNotEmpty);
      expect(env['flutter'], isNotEmpty);
      expect(env['platform'], isNotEmpty);
    });

    test('环境信息含端点选择结论（endpoint_host / endpoint_probe）', () {
      // 报告要能回答「客户端到底连的哪个域名」——否则用户报「连不上」时，
      // 无法判断是不是探测把地址升级到了一个不可达的源站。
      SpbEndpoints.resetForTest();
      final env = diagnosticsEnvironment();

      // 未探测：chosenHost 为 null → 写「(未探测)」而不是空串。
      expect(env['endpoint_host'], '(未探测)');
      expect(env['endpoint_probe'], 'skipped');
    });

    test('端点可达时报告里是 upgraded + preferred host', () async {
      SpbEndpoints.resetForTest();
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      await resolveEndpointsAtStartup(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => true,
        timeout: const Duration(milliseconds: 5),
      );

      final env = diagnosticsEnvironment();
      expect(env['endpoint_probe'], 'upgraded');
      expect(env['endpoint_host'], 'v6.example.com');
      // 报告里的 api 也应已是升级后的地址（两者必须一致，否则报障时
      // 「连的哪个域名」这个问题会有两个互相矛盾的答案）。
      expect(env['api'], contains('v6.example.com'));
    });

    test('端点不可达时报告里是 kept + 编译期 host', () async {
      SpbEndpoints.resetForTest();
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      await resolveEndpointsAtStartup(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => false,
        timeout: const Duration(milliseconds: 5),
      );

      final env = diagnosticsEnvironment();
      expect(env['endpoint_probe'], 'kept');
      expect(env['endpoint_host'], compiledHost);
      expect(env['api'], SpbEnv.apiBaseUrl);
    });

    test('环境信息**不含**任何 token / secret 键', () {
      // 这是本功能的安全红线：报告会被用户贴进公开 issue。
      // 键名黑名单（而非白名单）在这里是刻意的——将来新增环境字段时，
      // 若它叫 `xxx_token`，本用例会立刻失败并逼作者确认。
      final env = diagnosticsEnvironment();
      final suspicious = RegExp(
        r'token|secret|password|passwd|credential|authorization|apikey|api_key',
        caseSensitive: false,
      );

      final offenders = env.keys.where(suspicious.hasMatch).toList();
      expect(offenders, isEmpty, reason: '诊断环境信息不得含疑似凭据字段：$offenders');
    });

    test('导出路径会再掩一次（环境信息混进 header 也不会泄漏）', () async {
      // 端到端：环境信息 + 日志 + 报告头全部过 redactSecrets。
      SpbLog.error('请求失败', error: 'Authorization: Bearer sk-abcdefghijklmnop');

      String? captured;
      final caps = _RecordingCapabilities(
        onSave: (text, suggestedName) => captured = text,
      );

      await exportDiagnosticsReport(caps);

      expect(captured, isNot(contains('sk-abcdefghijklmnop')));
      expect(captured, isNot(contains('Bearer')));
    });

    test('不支持的平台（Noop）返回 unsupported，不抛', () async {
      // 移动端路径：`NoopDesktopCapabilities.saveDiagnostics` 恒 unsupported。
      final outcome = await exportDiagnosticsReport(
        const NoopDesktopCapabilities(),
      );
      expect(outcome, DiagnosticsExportOutcome.unsupported);
    });
  });
}

/// 记录 `saveDiagnostics` 收到的内容的能力桩。
class _RecordingCapabilities implements DesktopCapabilities {
  _RecordingCapabilities({required this.onSave});

  final void Function(String text, String suggestedName) onSave;

  @override
  bool get isSupported => true;

  @override
  Future<DiagnosticsExportOutcome> saveDiagnostics(
    String text, {
    required String suggestedName,
  }) async {
    onSave(text, suggestedName);
    return DiagnosticsExportOutcome.saved;
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> showWindow(WindowRole role) async {}
  @override
  Future<void> hideWindow(WindowRole role) async {}
  @override
  Future<bool> registerHotkey(String id, HotkeyBinding binding) async => false;
  @override
  Future<void> unregisterHotkey(String id) async {}
  @override
  Future<bool> isLaunchAtStartupEnabled() async => false;
  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}
  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async {}
  @override
  Future<void> setTrayTooltip(String tooltip) async {}
  @override
  Future<String?> pickDirectory({String? title}) async => null;
  @override
  Future<bool> revealPath(String path) async => false;
  @override
  Future<bool> openFile(String path) async => false;
  @override
  Future<void> dispose() async {}
}

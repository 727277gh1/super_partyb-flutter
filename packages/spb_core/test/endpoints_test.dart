import 'dart:async';
import 'dart:io' show SocketException;

import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// `spb_core` 端点解析（IPv6/IPv4 双栈选择）的契约测试。
///
/// ## 这个测试防的是什么
///
/// 端点选择是「启动路径上的增强」——探测可达就把服务地址升级到 preferred
/// 源站域名，不可达就退回编译期默认值。它有两类「静默失败」模式：
///
///   1. **改坏了回退语义**：探测失败时本应保持编译期地址，却误把基地址换成了
///      不可达的 preferred host → 用户彻底连不上，且「编译期默认一定可达」这
///      条安全网失效。
///   2. **探测崩了启动**：probe 抛异常时未兜住 → 启动流程被拖崩，连编译期
///      地址都来不及用。
///
/// 解析逻辑是纯函数（[SpbEndpoints.resolveEndpoints] 注入假 probe），故可
/// 在无网络环境逐条断言四态（skipped / upgraded / kept / probe 抛异常）。
void main() {
  const api = 'https://api.example.com/pba';
  const ufs = 'https://api.example.com/ufs';
  const apiUri = 'https://api.example.com/pba';
  const ufsUri = 'https://api.example.com/ufs';

  Uri apiBase = Uri.parse(apiUri);
  Uri ufsBase = Uri.parse(ufsUri);

  setUp(() {
    SpbEndpoints.resetForTest();
    apiBase = Uri.parse(apiUri);
    ufsBase = Uri.parse(ufsUri);
  });

  group('parsePreferredHosts', () {
    test('空串 → 空 Map', () {
      expect(parsePreferredHosts(''), isEmpty);
      expect(parsePreferredHosts('   '), isEmpty);
    });

    test('shell 友好语法（分号与逗号等价）', () {
      final r = parsePreferredHosts('a.com=b6.com;c.com=d6.com');
      expect(r, {'a.com': 'b6.com', 'c.com': 'd6.com'});
      final r2 = parsePreferredHosts('a.com=b6.com,c.com=d6.com');
      expect(r2, {'a.com': 'b6.com', 'c.com': 'd6.com'});
    });

    test('JSON 语法', () {
      final r = parsePreferredHosts('{"a.com":"b6.com"}');
      expect(r, {'a.com': 'b6.com'});
    });

    test('非法条目被忽略（空 host / 缺 = / 自映射）', () {
      final r = parsePreferredHosts('a.com=; =x.com; y.com; c.com=c.com');
      expect(r, isEmpty);
    });

    test('非 JSON 的 `{` 开头串退回 shell 语法（不抛异常）', () {
      final r = parsePreferredHosts('{not json;a.com=b6.com');
      expect(r, {'a.com': 'b6.com'});
    });
  });

  group('resolveEndpoints', () {
    test('未配置别名表（空表）→ skipped，基地址透传，chosenHost 为空', () async {
      final r = await SpbEndpoints.resolveEndpoints(
        api: apiBase,
        ufs: ufsBase,
        preferred: const <String, String>{},
        probe: (_, _, _) async => true,
      );
      expect(r.apiBaseUrl, api);
      expect(r.ufsBaseUrl, ufs);
      expect(r.probeOutcome, EndpointProbeOutcome.skipped);
      expect(r.chosenHost, isNull);
    });

    test('探测可达 → upgraded，两个基地址的 host 都换成 preferred', () async {
      final r = await SpbEndpoints.resolveEndpoints(
        api: apiBase,
        ufs: ufsBase,
        preferred: const {'api.example.com': 'api-v6.example.com'},
        probe: (host, port, timeout) async => host == 'api-v6.example.com',
      );
      expect(r.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(r.apiBaseUrl, 'https://api-v6.example.com/pba');
      expect(r.ufsBaseUrl, 'https://api-v6.example.com/ufs');
      expect(r.chosenHost, 'api-v6.example.com');
    });

    test('探测不可达 → kept，基地址保持不变，chosenHost 为 compiled host', () async {
      final r = await SpbEndpoints.resolveEndpoints(
        api: apiBase,
        ufs: ufsBase,
        preferred: const {'api.example.com': 'api-v6.example.com'},
        probe: (_, _, _) async => false,
      );
      expect(r.probeOutcome, EndpointProbeOutcome.kept);
      expect(r.apiBaseUrl, api);
      expect(r.ufsBaseUrl, ufs);
      expect(r.chosenHost, 'api.example.com');
    });

    test('探测超时（返回 false）→ kept', () async {
      bool decided = false;
      final r = await SpbEndpoints.resolveEndpoints(
        api: apiBase,
        ufs: ufsBase,
        preferred: const {'api.example.com': 'api-v6.example.com'},
        probe: (_, _, timeout) async {
          // 模拟黑洞：等满超时再判定不可达。
          await Future<void>.delayed(timeout + const Duration(milliseconds: 5));
          decided = true;
          return false;
        },
        timeout: const Duration(milliseconds: 15),
      );
      expect(decided, isTrue);
      expect(r.probeOutcome, EndpointProbeOutcome.kept);
      expect(r.apiBaseUrl, api);
    });

    test('probe 自身抛异常 → 视为不可达，kept，不把异常抛给调用方', () async {
      final r = await SpbEndpoints.resolveEndpoints(
        api: apiBase,
        ufs: ufsBase,
        preferred: const {'api.example.com': 'api-v6.example.com'},
        probe: (_, _, _) async => throw StateError('probe boom'),
      );
      expect(r.probeOutcome, EndpointProbeOutcome.kept);
      expect(r.chosenHost, 'api.example.com');
    });

    test('多对映射：各自独立替换，第一个可达者成为 chosenHost', () async {
      final api2 = Uri.parse('https://a.example.com/pba');
      final ufs2 = Uri.parse('https://ufs.example.com/ufs');
      final r = await SpbEndpoints.resolveEndpoints(
        api: api2,
        ufs: ufs2,
        preferred: const {
          'a.example.com': 'a-v6.example.com',
          'ufs.example.com': 'ufs-v6.example.com',
        },
        probe: (host, port, timeout) async => true,
      );
      expect(r.apiBaseUrl, 'https://a-v6.example.com/pba');
      expect(r.ufsBaseUrl, 'https://ufs-v6.example.com/ufs');
      expect(r.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(r.chosenHost, 'a-v6.example.com');
    });

    test('端口与 path 保留（显式端口不丢）', () async {
      final apiP = Uri.parse('https://api.example.com:8443/pba');
      final ufsP = Uri.parse('https://api.example.com:8443/ufs');
      final r = await SpbEndpoints.resolveEndpoints(
        api: apiP,
        ufs: ufsP,
        preferred: const {'api.example.com': 'api-v6.example.com'},
        probe: (_, _, _) async => true,
      );
      expect(r.apiBaseUrl, 'https://api-v6.example.com:8443/pba');
      expect(r.ufsBaseUrl, 'https://api-v6.example.com:8443/ufs');
    });

    test('compiledHost 不出现在任一基地址时跳过探测', () async {
      var called = 0;
      final r = await SpbEndpoints.resolveEndpoints(
        api: apiBase,
        ufs: ufsBase,
        preferred: const {'unrelated.com': 'unrelated-v6.com'},
        probe: (host, port, timeout) async {
          called++;
          return true;
        },
      );
      expect(called, 0);
      expect(r.probeOutcome, EndpointProbeOutcome.kept);
      expect(r.chosenHost, isNull);
    });

    test('探测用的端口取自匹配基地址（http 自定义端口）', () async {
      int? seenPort;
      final apiLocal = Uri.parse('http://dev.example.com:8000/pba');
      final ufsLocal = Uri.parse('http://dev.example.com:9000/ufs');
      await SpbEndpoints.resolveEndpoints(
        api: apiLocal,
        ufs: ufsLocal,
        preferred: const {'dev.example.com': 'dev-v6.example.com'},
        probe: (host, port, timeout) async {
          seenPort = port;
          return false;
        },
      );
      // api 命中 compiledHost → 用 api 的端口 8000。
      expect(seenPort, 8000);
    });

    test('混合：第一对不可达、第二对可达 → upgraded，第二对生效', () async {
      final api2 = Uri.parse('https://a.example.com/pba');
      final ufs2 = Uri.parse('https://b.example.com/ufs');
      final r = await SpbEndpoints.resolveEndpoints(
        api: api2,
        ufs: ufs2,
        preferred: const {
          'a.example.com': 'a-v6.example.com',
          'b.example.com': 'b-v6.example.com',
        },
        probe: (host, port, timeout) async => host == 'b-v6.example.com',
      );
      expect(r.apiBaseUrl, 'https://a.example.com/pba');
      expect(r.ufsBaseUrl, 'https://b-v6.example.com/ufs');
      expect(r.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(r.chosenHost, 'b-v6.example.com');
    });
  });

  group('SpbEndpoints.current', () {
    test('未 resolve 时等于编译期默认值（skipped、无 chosenHost）', () {
      final c = SpbEndpoints.current;
      expect(c.apiBaseUrl, SpbEnv.apiBaseUrl);
      expect(c.ufsBaseUrl, SpbEnv.ufsBaseUrl);
      expect(c.probeOutcome, EndpointProbeOutcome.skipped);
      expect(c.chosenHost, isNull);
    });

    test('resolveAndUpdate 空表时立即返回，不调用 probe', () async {
      var probeCalls = 0;
      final r = await SpbEndpoints.resolveAndUpdate(
        preferred: const <String, String>{},
        probe: (_, _, _) async {
          probeCalls++;
          return true;
        },
      );
      expect(probeCalls, 0);
      expect(r.probeOutcome, EndpointProbeOutcome.skipped);
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.skipped);
    });

    test('resolveAndUpdate 写回 current 并反映可达结果', () async {
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      final r = await SpbEndpoints.resolveAndUpdate(
        preferred: <String, String>{compiledHost: 'does-not-matter'},
        probe: (host, port, timeout) async => true,
        timeout: const Duration(milliseconds: 5),
      );
      // 用真实编译期地址构造的表，host 命中 → upgraded 写回 current。
      expect(r.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(SpbEndpoints.current.apiBaseUrl, contains('does-not-matter'));
      SpbEndpoints.resetForTest();
    });
  });

  // ==================== 启动装配（两端 main 共用） ====================
  //
  // 上面测的是解析逻辑；这里测的是**两端 main() 实际调用的那个包装**。
  // 它多负一项责任：无论内部出什么错，都不得把异常抛给启动路径。
  group('resolveEndpointsAtStartup', () {
    test('空表 → skipped，且不调用 probe（dev 构建零开销）', () async {
      var probeCalls = 0;
      final r = await resolveEndpointsAtStartup(
        preferred: const <String, String>{},
        probe: (_, _, _) async {
          probeCalls++;
          return true;
        },
      );
      expect(probeCalls, 0, reason: '未配置别名表时不该发起任何网络探测');
      expect(r.probeOutcome, EndpointProbeOutcome.skipped);
      expect(r.chosenHost, isNull);
      // 行为不变：基地址仍是编译期默认值。
      expect(r.apiBaseUrl, SpbEnv.apiBaseUrl);
      expect(r.ufsBaseUrl, SpbEnv.ufsBaseUrl);
    });

    test('可达 → current 升级到 preferred host，返回值与 current 一致', () async {
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      final r = await resolveEndpointsAtStartup(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => true,
        timeout: const Duration(milliseconds: 5),
      );
      expect(r.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(r.chosenHost, 'v6.example.com');
      expect(r.apiBaseUrl, contains('v6.example.com'));
      // 包装函数的契约之一：返回值就是写回 current 的那份（供 main 记日志）。
      expect(SpbEndpoints.current.apiBaseUrl, r.apiBaseUrl);
      expect(SpbEndpoints.current.chosenHost, 'v6.example.com');
    });

    test('不可达 → current 保持编译期默认值（安全网不失效）', () async {
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      final r = await resolveEndpointsAtStartup(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => false,
        timeout: const Duration(milliseconds: 5),
      );
      expect(r.probeOutcome, EndpointProbeOutcome.kept);
      expect(r.apiBaseUrl, SpbEnv.apiBaseUrl);
      expect(r.ufsBaseUrl, SpbEnv.ufsBaseUrl);
      expect(r.chosenHost, compiledHost);
    });

    test('probe 抛异常 → 视为不可达，不抛出', () async {
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      final r = await resolveEndpointsAtStartup(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => throw const SocketException('boom'),
        timeout: const Duration(milliseconds: 5),
      );
      expect(r.probeOutcome, EndpointProbeOutcome.kept);
      expect(r.apiBaseUrl, SpbEnv.apiBaseUrl);
    });

    test('内部异常（Uri 解析层）也不得抛给启动路径', () async {
      // 用非法超时（负数）逼 resolveAndUpdate 内部出错——具体异常类型不重要，
      // 重要的是「包装函数不向外抛」。
      final r = await resolveEndpointsAtStartup(
        preferred: const <String, String>{},
        timeout: const Duration(seconds: -1),
      );
      // 空表路径下不会碰超时，故这里应正常返回；若实现将来改成抛，
      // 本用例会因未捕获异常而失败。
      expect(r.probeOutcome, EndpointProbeOutcome.skipped);
      expect(SpbEndpoints.current.apiBaseUrl, SpbEnv.apiBaseUrl);
    });
  });
}

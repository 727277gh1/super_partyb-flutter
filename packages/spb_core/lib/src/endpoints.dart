import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io' show Socket;

import 'env.dart';
import 'logger.dart';

/// 端点探测的默认超时。
///
/// 选 1.5s 的理由：
/// - 「无 IPv6 地址」的环境（本机实测）连接在 ~10ms 内即失败
///   （`errno=99 Cannot assign requested address`），根本碰不到这个上限；
/// - 只有「有 IPv6 地址但路由黑洞」这种少见情形才会真正等满超时，
///   1.5s 是「让黑洞场景比一次正常请求多等的可接受代价」。
///
/// 与桌面 `bootstrapDesktop` / 移动 `authDeepLinkReceiver.start` 并发执行时，
/// 这个超时被它们的耗时隐藏（见两端 `main.dart` 的 `Future.wait`）。
const Duration defaultProbeTimeout = Duration(milliseconds: 1500);

/// 探测函数：给定 host/port/超时，返回该端点是否「可建立 TCP 连接」。
///
/// 抽成 typedef 而非直接用 `Socket.connect`：解析逻辑（[resolveEndpoints]）
/// 要能在无网络环境下单测，故把真实的网络动作注入进来。
typedef EndpointProbe = Future<bool> Function(
  String host,
  int port,
  Duration timeout,
);

/// 一次端点解析的结论（「是否做了探测、结果如何」）。
///
/// 诊断报告用它回答「为什么用户连的是 tbcc 而不是 tbcc6」——
/// `skipped` 说明根本没配置别名表，`kept` 说明探测了但源站不可达。
enum EndpointProbeOutcome {
  /// 未配置别名表（或表为空），未做探测，基地址维持编译期值。
  skipped,

  /// 探测到至少一个 preferred host 可达，基地址已升级。
  upgraded,

  /// 配置了别名表，但所有 preferred host 都不可达，基地址保持编译期值。
  kept,
}

/// 默认探测实现：用 [Socket.connect] 发起一次真实 TCP 连接。
///
/// 成功即销毁 socket（只要「能连上」即可，不发任何应用层数据）；
/// 任何异常（连接被拒 / DNS 失败 / 超时 / 黑洞）都视为「不可达」返回 false。
///
/// ## 为什么探测必须用真连接而不是查本机接口
///
/// `NetworkInterface.list(type: IPv6)` 只能告诉你「本机有没有 IPv6 地址」，
/// 不能告诉你「能不能路由到源站」——黑洞场景（有地址但路由不通）正是
/// 本机制要解决的主要问题，只有真正握一次 TCP 才是权威判据。
Future<bool> defaultEndpointProbe(
  String host,
  int port,
  Duration timeout,
) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } catch (_) {
    // 连接失败即不可达：连接超时 / DNS 失败 / 路由黑洞 / 连接被拒，
    // 一律归为「该端点不可达」，由上层按编译期默认值继续。
    return false;
  }
}

/// 解析别名表原始字符串为 `compiledHost → preferredHost` 映射。
///
/// 支持两种语法（与小程序 `TARO_APP_HOST_FALLBACKS` 同构，便于运维两处共用
/// 一份配置）：
/// - **shell 友好**（推荐）：`api.example.com=api-v6.example.com`，
///   多对用 `;` 或 `,` 分隔；
/// - **JSON**：`{"api.example.com":"api-v6.example.com"}`（以 `{` 开头才尝试）。
///
/// 空 / 未设置 / 全部非法 → 空 `Map` → [resolveEndpoints] 退化为透传
/// （行为与未引入本机制完全一致，便于回退）。
///
/// 非法条目（空 host、缺少 `=`、自映射 `a=a`）被静默忽略——配置错不该让启动崩。
Map<String, String> parsePreferredHosts(String raw) {
  final result = <String, String>{};
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return result;

  // 先尝试 JSON（仅当形如对象字面量时）。
  if (trimmed.startsWith('{')) {
    final decoded = _tryDecodeJson(trimmed);
    if (decoded != null) {
      decoded.forEach((key, value) {
        if (key is String && value is String) {
          final k = key.trim();
          final v = value.trim();
          if (k.isNotEmpty && v.isNotEmpty && k != v) {
            result[k] = v;
          }
        }
      });
      return result;
    }
    // JSON 解析失败 → 落到 shell 友好语法（容忍配置者两种语法混用）。
  }

  for (final pair in trimmed.split(RegExp(r'[;,]'))) {
    final idx = pair.indexOf('=');
    if (idx <= 0) continue;
    final k = pair.substring(0, idx).trim();
    final v = pair.substring(idx + 1).trim();
    if (k.isNotEmpty && v.isNotEmpty && k != v) {
      result[k] = v;
    }
  }
  return result;
}

Map<Object?, Object?>? _tryDecodeJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<Object?, Object?> ? decoded : null;
  } catch (_) {
    // JSON 解析失败：返回 null，让调用方走 shell 语法分支。
    return null;
  }
}

/// 一组解析后的服务基地址 + 探测结论。
///
/// **不可变值对象**。进程级的可变状态由静态字段 [current] 持有。
class SpbEndpoints {
  const SpbEndpoints({
    required this.apiBaseUrl,
    required this.ufsBaseUrl,
    required this.chosenHost,
    required this.probeOutcome,
  });

  /// 解析后的 Go API 基地址（替换过 host 后的完整 URL）。
  final String apiBaseUrl;

  /// 解析后的 UFS 基地址。
  final String ufsBaseUrl;

  /// 实际生效的服务 host（即 [apiBaseUrl] 的 host）。
  ///
  /// - 探测后升级（[EndpointProbeOutcome.upgraded]）：preferred host；
  /// - 探测后保持（[EndpointProbeOutcome.kept]）：第一个被探测的 compiled host；
  /// - 未探测（[EndpointProbeOutcome.skipped]）：`null`（诊断报告据此显示
  ///   「未探测」，与「探测过但保持」区分开）。
  final String? chosenHost;

  /// 探测结论。
  final EndpointProbeOutcome probeOutcome;

  /// 进程级持有者：所有运行期消费点应读它而非直接读 [SpbEnv]。
  ///
  /// 初始化为编译期值（[SpbEnv.apiBaseUrl] / [SpbEnv.ufsBaseUrl]），
  /// 由 [resolveAndUpdate] 在启动时覆盖。**未调用 resolve 时等同编译期值**，
  /// 行为零变化——这是「端点选择是增强而非必需」的体现。
  static SpbEndpoints current = const SpbEndpoints(
    apiBaseUrl: SpbEnv.apiBaseUrl,
    ufsBaseUrl: SpbEnv.ufsBaseUrl,
    chosenHost: null,
    probeOutcome: EndpointProbeOutcome.skipped,
  );

  /// 解析端点别名表并探测，把结果写回 [current]。
  ///
  /// 生产路径不直接调本方法，而是调 [resolveEndpointsAtStartup]（它额外
  /// 负起「不拖崩启动」的责任），并在两端 `main()` 里与其余启动步骤并发：
  ///
  /// ```dart
  /// final results = await Future.wait<Object?>([
  ///   bootstrapDesktop(binding),
  ///   resolveEndpointsAtStartup(),
  /// ]);
  /// ```
  /// - [preferred] 缺省时从 [SpbEnv.preferredHostsRaw] 解析；留空则立即返回
  ///   （不探测、不阻塞）。
  /// - [probe] 缺省时用 [defaultEndpointProbe]（真实 TCP 连接）；测试可注入
  ///   假实现避免碰网络。
  /// - 探测失败 / 超时 / 抛异常一律视为「不可达」，绝不把异常抛给调用方
  ///   （端点选择是启动路径上的增强，不能拖崩启动）。
  static Future<SpbEndpoints> resolveAndUpdate({
    Map<String, String>? preferred,
    EndpointProbe? probe,
    Duration timeout = defaultProbeTimeout,
  }) async {
    final table = preferred ?? parsePreferredHosts(SpbEnv.preferredHostsRaw);
    final (apiUri, ufsUri) = _parseBaseUris();
    final resolved = await resolveEndpoints(
      api: apiUri,
      ufs: ufsUri,
      preferred: table,
      probe: probe ?? defaultEndpointProbe,
      timeout: timeout,
    );
    current = resolved;
    return resolved;
  }

  /// 解析逻辑的纯函数核心（无副作用、可注入探测实现、可在无网络环境单测）。
  ///
  /// 规则：
  /// - [preferred] 为空 → 直接返回 `api`/`ufs` 的字符串形式，结论
  ///   [EndpointProbeOutcome.skipped]。
  /// - 否则按插入顺序遍历每对 `compiledHost → preferredHost`：
  ///   - `compiledHost` 在 `api`/`ufs` 中都不出现时**跳过**（探测它无意义，
  ///     因为即便可达也没地方替换）；
  ///   - 用对应基地址的端口探测 `preferredHost`（命中哪个基地址就用它的端口，
  ///     都不命中则默认 443）；
  ///   - 可达 → 把两个基地址里 host == `compiledHost` 的部分替换为
  ///     `preferredHost`（`Uri.replace(host:)` 保留 scheme/port/path）。
  /// - 至少一对可达 → [EndpointProbeOutcome.upgraded]，[chosenHost] 为第一个
  ///   可达的 preferred host；全部不可达 → [EndpointProbeOutcome.kept]，
  ///   [chosenHost] 为第一个被探测的 compiled host。
  static Future<SpbEndpoints> resolveEndpoints({
    required Uri api,
    required Uri ufs,
    required Map<String, String> preferred,
    required EndpointProbe probe,
    Duration timeout = defaultProbeTimeout,
  }) async {
    if (preferred.isEmpty) {
      return SpbEndpoints(
        apiBaseUrl: api.toString(),
        ufsBaseUrl: ufs.toString(),
        chosenHost: null,
        probeOutcome: EndpointProbeOutcome.skipped,
      );
    }

    var resolvedApi = api;
    var resolvedUfs = ufs;
    String? firstUpgraded;
    String? firstKeptCompiled;
    var touchedAny = false;

    for (final entry in preferred.entries) {
      final compiledHost = entry.key;
      final preferredHost = entry.value;

      // compiledHost 不在任一基地址里 → 探测它无意义（没有可替换的位置）。
      if (api.host != compiledHost && ufs.host != compiledHost) continue;

      firstKeptCompiled ??= compiledHost;

      final port = _portFor(api: api, ufs: ufs, host: compiledHost);
      bool reachable;
      try {
        reachable = await probe(preferredHost, port, timeout);
      } catch (_) {
        // probe 自身抛异常也视为「不可达」：探测是启动路径上的增强，
        // 绝不允许它把启动流程带崩。
        reachable = false;
      }
      if (!reachable) continue;

      resolvedApi = _rewriteHost(resolvedApi, compiledHost, preferredHost);
      resolvedUfs = _rewriteHost(resolvedUfs, compiledHost, preferredHost);
      firstUpgraded ??= preferredHost;
      touchedAny = true;
    }

    return SpbEndpoints(
      apiBaseUrl: resolvedApi.toString(),
      ufsBaseUrl: resolvedUfs.toString(),
      chosenHost: touchedAny ? firstUpgraded : firstKeptCompiled,
      probeOutcome: touchedAny
          ? EndpointProbeOutcome.upgraded
          : EndpointProbeOutcome.kept,
    );
  }

  /// 解析编译期基地址为 `Uri`；解析失败时回退到一个占位 URI（保证启动不崩）。
  ///
  /// 失败只可能在 CI 注入了非法 URL 时发生——这种情况下端点选择本就无从谈起，
  /// 让后续真实请求用原字符串失败、把错误暴露给用户，比在这里崩启动更可调试。
  static (Uri, Uri) _parseBaseUris() {
    final api = _tryParseUri(SpbEnv.apiBaseUrl) ?? Uri.parse('http://invalid');
    final ufs = _tryParseUri(SpbEnv.ufsBaseUrl) ?? Uri.parse('http://invalid');
    return (api, ufs);
  }

  /// 仅测试用：把 [current] 重置为编译期默认值。
  ///
  /// 生产代码不应调用——它会让「导出诊断日志」报告里少一条端点结论。
  /// 全局单例会在用例之间累积，断言「解析后的基地址」之前必须先重置。
  static void resetForTest() {
    current = const SpbEndpoints(
      apiBaseUrl: SpbEnv.apiBaseUrl,
      ufsBaseUrl: SpbEnv.ufsBaseUrl,
      chosenHost: null,
      probeOutcome: EndpointProbeOutcome.skipped,
    );
  }

  @override
  String toString() =>
      'SpbEndpoints(api=$apiBaseUrl, ufs=$ufsBaseUrl, '
      'chosen=${chosenHost ?? '-'}, outcome=${probeOutcome.name})';
}

/// 启动阶段调用一次：解析端点、写回 [SpbEndpoints.current]、**不抛异常**。
///
/// 编译期基地址（`--dart-define=SPB_API_BASE_URL` 等）是**一定可达**的那个；
/// 本函数探测 preferred 源站域名，可达才把基地址升级过去。故失败/超时的
/// 最坏结果是「停留在编译期地址」，而不是让客户端连不上。
///
/// 返回解析后的结果（永远非空）；异常时返回未变更的 [SpbEndpoints.current]，
/// 由调用方决定怎么记日志。
///
/// ## 为什么不直接让调用方 `await SpbEndpoints.resolveAndUpdate()`
///
/// 因为**异常语义**不同：`resolveAndUpdate` 虽然把探测失败吞成「不可达」，
/// 但配置解析、`Uri.parse` 等仍可能抛。它跑在启动路径上且与
/// `bootstrapDesktop` / `authDeepLinkReceiver.start` 并发（见两端
/// `main.dart`），一次抛出就会让 `runApp` 不执行——用户看到白窗口，
/// 而真正原因只是「端点探测出了点问题」（本该降级）。
///
/// [preferred] / [probe] / [timeout] 仅供测试注入；生产调用不带参数，
/// 走 `SpbEnv.preferredHostsRaw` + 真实 TCP 探测。
Future<SpbEndpoints> resolveEndpointsAtStartup({
  Map<String, String>? preferred,
  EndpointProbe? probe,
  Duration timeout = defaultProbeTimeout,
}) async {
  try {
    return await SpbEndpoints.resolveAndUpdate(
      preferred: preferred,
      probe: probe,
      timeout: timeout,
    );
  } on Object catch (e) {
    // 端点选择是启动路径上的增强，不能把启动拖崩（见上方说明）。
    SpbLog.warn('服务端点解析失败，使用编译期默认地址', {'error': '$e'});
    return SpbEndpoints.current;
  }
}

Uri? _tryParseUri(String raw) {
  try {
    return Uri.parse(raw);
  } catch (_) {
    // Uri.parse 对非法输入抛 FormatException；返回 null 让上层回退。
    return null;
  }
}

Uri _rewriteHost(Uri uri, String from, String to) {
  if (uri.host != from) return uri;
  return uri.replace(host: to);
}

/// 取 `host` 在 `api`/`ufs` 中使用的端口；都不命中则用 443（HTTPS 默认）。
int _portFor({required Uri api, required Uri ufs, required String host}) {
  if (api.host == host) return api.port;
  if (ufs.host == host) return ufs.port;
  return 443;
}

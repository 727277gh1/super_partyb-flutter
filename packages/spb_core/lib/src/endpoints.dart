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

  /// 曾经升级过，**运行中**因连续网络失败而主动退回编译期地址（issue #50）。
  ///
  /// ## 为什么必须与 [kept] 区分开
  ///
  /// 两者的基地址相同（都是编译期值），但**语义与后续行为完全不同**：
  ///
  /// | 结论 | 含义 | 之后该做什么 |
  /// |---|---|---|
  /// | [kept] | 探测过，preferred 从来就没通 | 冷却后应重探（网络可能变了） |
  /// | `downgraded` | 本来在 preferred 上跑，因网络变化退回 | **冷却后应重探升级** |
  ///
  /// 合并成一个值会让「降级后自动恢复」失去触发依据——那正是 issue #50
  /// 里「只降不升」退化路径的根源。诊断报告也据此回答「为什么用户现在
  /// 连的是 CDN」（是启动就没有 IPv6，还是运行中降级了）。
  downgraded,
}

/// 端点失败信号的形态（决定是否计入「该降级了」）。
///
/// ## 为什么按形态分类，而不是「只要失败就计数」
///
/// 降级的判据必须是**确凿的网络不可达证据**。把 4xx/5xx 也算进去会让
/// 「服务端返回 500」误触发降级——源站本身是通的，只是业务出错。
/// 这与 `spb_domain` 的 `outbox.isRetryable` 同一取向（用错误类型而非猜测）。
enum EndpointFailureKind {
  /// 连接层失败（连接超时 / 拒绝 / DNS 失败 / 无路由 / TLS 握手失败）。
  /// 只有这一类计入降级判据。
  connectivity,

  /// 已建立连接但服务端返回错误（4xx / 5xx）。**不计入**降级判据。
  server,

  /// 用户取消 / 请求被上层丢弃。不计入。
  cancelled,
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

  /// 基地址发生变化时广播（issue #50 运行中降级/升级）。
  ///
  /// ## 为什么用 broadcast 而不是单订阅
  ///
  /// 装配层有**多个**消费者（两端的 `sseClientProvider` 换 host、诊断/日志
  /// 监听），而单订阅流只允许一个 listen 者。broadcast 也保证「没人监听时
  /// 不缓存事件」——降级只对**当前**配置有意义，补发历史事件没有意义。
  static final StreamController<SpbEndpoints> _changes =
      StreamController<SpbEndpoints>.broadcast();

  /// 基地址变化流。仅当 [current] 的**基地址字符串**真的变了才发事件
  /// （`kept → downgraded` 这种「结论变了但地址没变」不发）。
  static Stream<SpbEndpoints> get changes => _changes.stream;

  /// 写回 [current]，并在基地址变化时广播。
  ///
  /// 所有写 [current] 的路径都必须经过这里——直接赋值会让装配层收不到
  /// 变化，表现为「日志说降级了，但 SSE 还在重连旧 host」。
  static void _apply(SpbEndpoints next) {
    final previous = current;
    current = next;
    if (previous.apiBaseUrl == next.apiBaseUrl &&
        previous.ufsBaseUrl == next.ufsBaseUrl) {
      return;
    }
    if (!_changes.isClosed) _changes.add(next);
  }

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
    // 注意 [SpbEndpoints.resolveEndpoints] 只产出 skipped/upgraded/kept——
    // `downgraded` 是**运行中**才有的结论，见 [downgrade] 与 [EndpointGuard]。
    _apply(resolved);
    return resolved;
  }

  /// 运行中降级（issue #50）：把基地址退回编译期默认值。
  ///
  /// ## 为什么降级**不做探测**
  ///
  /// 降级的触发信号本身就是「连不上」，此刻再探测只会把「用户等待」延长一个
  /// 超时（1.5s）。而退回编译期地址的代价极小——那是「一定可达」的双栈 CDN，
  /// 与 `kept` 的落点完全相同。降级要快，升级才需要证据。
  ///
  /// 返回降级后的端点；若当前**不在**升级态则什么都不做并返回 `current`
  /// （幂等：重复降级不会重复广播）。
  static SpbEndpoints downgrade({String reason = '连续网络失败'}) {
    final previous = current;
    if (previous.probeOutcome != EndpointProbeOutcome.upgraded) {
      return previous;
    }

    final (apiUri, ufsUri) = _parseBaseUris();
    final next = SpbEndpoints(
      apiBaseUrl: apiUri.toString(),
      ufsBaseUrl: ufsUri.toString(),
      chosenHost: apiUri.host,
      probeOutcome: EndpointProbeOutcome.downgraded,
    );
    _apply(next);
    SpbLog.warn('服务端点已降级回编译期默认地址', {
      'reason': reason,
      'from': previous.chosenHost ?? '(unknown)',
      'to': next.chosenHost ?? '(unknown)',
    });
    return next;
  }

  /// 是否处于「降级态」（可被冷却期后的重探升级）。
  static bool get isDowngraded =>
      current.probeOutcome == EndpointProbeOutcome.downgraded;

  /// 运行中重探（issue #50 升级路径）：**只在升级成功时**写回。
  ///
  /// ## 为什么不能直接复用 [resolveAndUpdate]
  ///
  /// `resolveAndUpdate` 在探测失败时会把结论写成 `kept`——那会把
  /// `downgraded` **覆盖掉**，而 [EndpointGuard.tryUpgrade] 是以
  /// 「当前是否降级/保持态」判断要不要重试的。覆盖成 `kept` 虽然仍在重试
  /// 集合内，但诊断报告里的「因网络变化降级过」这一信息会丢失；更糟的是
  /// 若将来把重试条件收窄为「仅 downgraded」，恢复循环就会静默终止。
  ///
  /// 别名表为空时直接返回 `current`（没有可升级的目标，也不该写回）。
  static Future<SpbEndpoints> reprobeForUpgrade({
    Map<String, String>? preferred,
    EndpointProbe? probe,
    Duration timeout = defaultProbeTimeout,
  }) async {
    final table = preferred ?? parsePreferredHosts(SpbEnv.preferredHostsRaw);
    if (table.isEmpty) return current;
    final (apiUri, ufsUri) = _parseBaseUris();
    final resolved = await resolveEndpoints(
      api: apiUri,
      ufs: ufsUri,
      preferred: table,
      probe: probe ?? defaultEndpointProbe,
      timeout: timeout,
    );
    if (resolved.probeOutcome != EndpointProbeOutcome.upgraded) {
      // 保留降级态（与当前 current 同一基地址），不发广播、不盖结论。
      return current;
    }
    _apply(resolved);
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
    _resetSilently();
    EndpointGuard.instance.resetForTest();
  }

  /// 重置为编译期默认值且**不广播**。
  ///
  /// 广播是 broadcast 流，不会给后来者补发历史事件，故不广播不会让测试漏事件。
  static void _resetSilently() {
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

/// 运行中网络失败的计数与升降级仲裁（issue #50）。
///
/// ## 为什么单拉一个类，而不是让调用方自己数失败次数
///
/// 升降级是**不对称迟滞**（hysteresis），三条规则互相牵制：
///
/// | 方向 | 触发 | 理由 |
/// |---|---|---|
/// | 降级（快） | 连续 [failureThreshold] 次**连接层**失败 → 立即退回编译期地址 | 失败是确凿证据，降级代价小（走 CDN 功能正常） |
/// | 升级（慢） | 处于降级/保持态 **且** 距上次切换 ≥ [upgradeCooldown] **且** 重探成功 | 升级代价大（错误升级 = 连不上），需防探测风暴 |
/// | 成功 | 任何一次成功响应清零计数，并（若未升级）按冷却期触发一次重探 | 否则计数会跨「好/坏」两段网络累积；重探又依赖「网络是通的」这个证据 |
///
/// 这套规则放在 `spb_core`（纯逻辑，可无头单测），**不碰网络**：重探用的
/// [probe] 可注入，装配层只需把失败信号喂进 [recordFailure] 并监听
/// [SpbEndpoints.changes]。
///
/// ## 为什么不用 `connectivity_plus` 之类的网络变化事件
///
/// 与 `spb_domain` 的 `outbox` 同一取向：桌面端「有没有默认路由」不等于
/// 「服务端可达」，而移动端 WiFi↔蜂窝切换时系统事件未必及时。用「请求真的
/// 失败了」作信号，既准确又跨平台一致。
class EndpointGuard {
  EndpointGuard._();

  /// 进程级单例（全局端点状态本身就是进程级的）。
  static final EndpointGuard instance = EndpointGuard._();

  /// 重探用的探测实现（测试注入假实现）。
  EndpointProbe probe = defaultEndpointProbe;

  /// 重探用的别名表（null = 从 `SpbEnv.preferredHostsRaw` 解析）。
  Map<String, String>? preferredOverride;

  /// 重探超时。
  Duration probeTimeout = defaultProbeTimeout;

  /// 时钟（测试可注入，避免真的等 5 分钟）。
  DateTime Function() now = DateTime.now;

  /// 连续多少次连接层失败后降级。
  ///
  /// 取 3 而不是 1：单次失败可能只是 DNS 抖动或第一个请求撞上网络切换的
  /// 中间态；连续 3 次（通常伴随 SSE 重连失败 + 一两个 API 请求）才是
  /// 「这个 host 真的不可达」的确凿证据。
  int failureThreshold = 3;

  /// 降级后至少隔多久才允许重探升级（冷却期）。
  ///
  /// 5 分钟的依据：移动端在「有/无 IPv6」两个网络间来回切的典型间隔是
  /// 分钟级；冷却期必须明显大于切换频率，否则会形成探测风暴。同时它不能
  /// 太长——否则用户切回有 IPv6 的网络后要等很久才恢复优化路径。
  Duration upgradeCooldown = const Duration(minutes: 5);

  int _consecutiveFailures = 0;
  DateTime? _lastSwitchAt;

  /// 上次**探测**的时刻（与 [_lastSwitchAt] 分开）。
  ///
  /// ## 为什么不能共用 [_lastSwitchAt]
  ///
  /// 降级时会写 [_lastSwitchAt]，但启动即 `kept`（探测失败）的场景下它
  /// 是 null。而 [recordSuccess] 每次成功都会尝试升级——没有独立的探测
  /// 节流，`kept` 态下就变成**每个请求都探一次**（每次 1.5s 超时 + 一次
  /// TCP 连接），这就是探测风暴。
  DateTime? _lastProbeAt;
  Timer? _upgradeTimer;
  bool _upgradeInFlight = false;

  /// 当前连续失败次数（诊断用）。
  int get consecutiveFailures => _consecutiveFailures;

  /// 是否已排上「冷却期后重探升级」的计时器（测试用）。
  bool get hasPendingUpgrade => _upgradeTimer != null;

  /// 记录一次请求失败。
  ///
  /// 只有 [EndpointFailureKind.connectivity] 计入判据；其余形态（服务端
  /// 4xx/5xx、用户取消）直接忽略——源站能返回错误码，说明**网络是通的**。
  ///
  /// 达到阈值且当前处于升级态 → 立即降级并安排冷却后的重探。
  void recordFailure(EndpointFailureKind kind) {
    if (kind != EndpointFailureKind.connectivity) return;
    if (SpbEndpoints.current.probeOutcome != EndpointProbeOutcome.upgraded) {
      // 已在编译期地址上：失败与端点选择无关，不计数（否则会把
      // 「CDN 自己挂了」记成「该降级」，而实际上已经无处可降）。
      return;
    }
    _consecutiveFailures++;
    if (_consecutiveFailures < failureThreshold) return;
    _downgradeNow();
  }

  /// 记录一次成功响应：清零计数，并（若未升级）按冷却期触发一次重探。
  ///
  /// ## 为什么成功也要触发重探
  ///
  /// 降级后唯一能确认「网络已经恢复」的证据就是**有请求成功**（探测信号
  /// 本身也可能是错报）。在成功响应后尝试一次升级：若在冷却期内则
  /// [tryUpgrade] 会自行拒绝；冷却期已过则正好借这次机会重探。
  ///
  /// 这也覆盖了启动即 `kept` 的场景——用户开机时没 IPv6、后来连上 WiFi
  /// 有了，下一次成功响应就会触发重探并自动升回源站。
  void recordSuccess() {
    _consecutiveFailures = 0;
    final outcome = SpbEndpoints.current.probeOutcome;
    if (outcome == EndpointProbeOutcome.upgraded) return;
    if (outcome == EndpointProbeOutcome.skipped) return; // 没配别名表，无处可升
    unawaited(tryUpgrade());
  }

  void _downgradeNow() {
    final failures = _consecutiveFailures;
    _consecutiveFailures = 0;
    _lastSwitchAt = now();
    SpbEndpoints.downgrade(reason: '连续 $failures 次网络失败');
    _scheduleUpgradeProbe();
  }

  void _scheduleUpgradeProbe() {
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer(upgradeCooldown, () {
      _upgradeTimer = null;
      unawaited(tryUpgrade());
    });
  }

  /// 距「上次切换/上次探测」是否已过冷却期。
  ///
  /// 取两者中**更晚**的那个：降级后立即不应重探（否则刚降就升，反复抖动），
  /// 而探测失败后也不应紧接着再探。
  bool _cooledDown() {
    final t = now();
    for (final stamp in [_lastSwitchAt, _lastProbeAt]) {
      if (stamp != null && t.difference(stamp) < upgradeCooldown) return false;
    }
    return true;
  }

  /// 立即尝试重探升级（冷却期后自动调用；也可由上层手动触发）。
  ///
  /// 成功（重探到 preferred 可达）→ 基地址回到 preferred 并发
  /// [SpbEndpoints.changes] 事件；失败 → **重新安排**下一轮重探，而不是
  /// 放弃（否则一次「正好在切换中间态」的重探会让恢复永久失效）。
  Future<void> tryUpgrade() async {
    if (_upgradeInFlight) return;
    final outcome = SpbEndpoints.current.probeOutcome;
    if (outcome != EndpointProbeOutcome.downgraded &&
        outcome != EndpointProbeOutcome.kept) {
      return;
    }
    if (!_cooledDown()) {
      // 冷却期未到（手动触发路径会走到这里）：等够再试。
      //
      // 用「最后一个切换/探测时刻」算剩余，而不是直接 `upgradeCooldown`：
      // 否则连续多次成功响应会把到期时刻一直往后推，恢复时间无界。
      var latest = _lastProbeAt ?? _lastSwitchAt;
      if (_lastSwitchAt != null &&
          (latest == null || _lastSwitchAt!.isAfter(latest))) {
        latest = _lastSwitchAt;
      }
      final remain = latest == null
          ? upgradeCooldown
          : upgradeCooldown - now().difference(latest);
      _upgradeTimer?.cancel();
      _upgradeTimer = Timer(remain, () {
        _upgradeTimer = null;
        unawaited(tryUpgrade());
      });
      return;
    }

    _upgradeInFlight = true;
    _lastProbeAt = now();
    try {
      final resolved = await SpbEndpoints.reprobeForUpgrade(
        preferred: preferredOverride,
        probe: probe,
        timeout: probeTimeout,
      );
      if (resolved.probeOutcome == EndpointProbeOutcome.upgraded) {
        _lastSwitchAt = now();
        _consecutiveFailures = 0;
        SpbLog.info('服务端点已恢复升级（重探成功）', {
          'host': resolved.chosenHost ?? '(unknown)',
        });
      } else {
        // 重探未成功：继续按冷却期重试。不放弃的理由见方法文档。
        _scheduleUpgradeProbe();
      }
    } finally {
      _upgradeInFlight = false;
    }
  }

  /// 取消挂起的计时器（测试/退出用）。
  void dispose() {
    _upgradeTimer?.cancel();
    _upgradeTimer = null;
    _upgradeInFlight = false;
  }

  /// 测试用：清空计数、计时器与冷却状态。
  void resetForTest() {
    dispose();
    _consecutiveFailures = 0;
    _lastSwitchAt = null;
    _lastProbeAt = null;
    probe = defaultEndpointProbe;
    preferredOverride = null;
    probeTimeout = defaultProbeTimeout;
    now = DateTime.now;
    failureThreshold = 3;
    upgradeCooldown = const Duration(minutes: 5);
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

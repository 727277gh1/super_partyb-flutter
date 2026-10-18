import 'dart:async';
import 'dart:io';

import 'package:spb_core/spb_core.dart';

import 'oidc_client.dart';

/// RFC 8252 §7.3 loopback 重定向接收器（桌面端）。
///
/// ## 机制（RFC 8252 §7.3 原文要点）
///
/// > Native apps ... can use the loopback interface to receive the OAuth
/// > redirect. Loopback redirect URIs use the "http" scheme and are
/// > constructed with the loopback IP literal and **whatever port the client
/// > is listening on**.
///
/// 客户端在 `127.0.0.1` 上临时 bind 一个**随机空闲端口**，把
/// `http://127.0.0.1:<port>/callback` 作为 `redirect_uri` 发起授权；IdP 侧
/// 只需注册**不含端口**的 `http://127.0.0.1/callback`（fosite 对 loopback
/// 注册值做端口通配）。授权完成后浏览器 302 到本端口，监听器取出 `code`。
///
/// ## 安全要点（全部对应 RFC 8252 的具体条款）
///
/// - **只绑定 loopback**（§7.3：listen on the loopback network interface
///   only）：请求不出本机，网络上的其他主机无法投递伪造回调；
/// - **随机端口**：避免固定端口被其他进程抢占或被同机恶意程序「蹲守」；
/// - **一次性**：收到合法回调即关停；超时自动关停——一个长期开着的监听端口
///   是不必要的暴露面；
/// - **state 防 CSRF**（§4.1 推荐）：回调的 `state` 与授权请求比对，由
///   [OidcPkce.parseCallback] 完成；
/// - **响应页**：给浏览器回一个最小 HTML，提示「回到应用」，不带任何 token
///   （token 只经 token 端点的 POST 响应交付，不进 URL、不进浏览器历史）。
///
/// ## 为什么是纯 Dart（`dart:io` HttpServer）
///
/// 本类放 `spb_api`（分层规则禁止 Flutter 依赖），`HttpServer` 是平台无关的
/// 标准能力，无需插件。Linux/Windows/macOS 行为一致。
class LoopbackRedirectServer {
  LoopbackRedirectServer._({
    required this.port,
    required HttpServer server,
    this.timeout = const Duration(minutes: 5),
  }) : _server = server;

  final HttpServer _server;

  /// 实际绑定的端口（`port 0` 由内核分配后的真实值）。
  final int port;

  /// 从 [start] 起算的最长等待时间。超时后监听器自动关停，[wait] 以
  /// [TimeoutException] 失败。
  final Duration timeout;

  Timer? _timer;
  bool _closed = false;
  final _completer = Completer<Uri>();

  /// 默认回调路径。必须与 IdP 注册值、授权请求里的 `redirect_uri` 路径一致。
  static const String defaultPath = '/callback';

  /// 在 loopback 的随机空闲端口上开始监听。
  ///
  /// [path] 是回调路径（须与 IdP 注册值一致），默认 [defaultPath]。
  static Future<LoopbackRedirectServer> start({
    String path = defaultPath,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    // 只绑 IPv4 loopback 字面量，不用 localhost：RFC 8252 §7.3 明确
    // 「use of localhost is NOT RECOMMENDED」，因为它可能解析到非回环地址，
    // 也避免与 IdP 注册的 127.0.0.1 字面量不匹配。
    //
    // `port: 0` = 由内核分配当前空闲端口，天然避开端口冲突，也让
    // 「同机两个用户各跑一份客户端」互不干扰。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final self = LoopbackRedirectServer._(
      port: server.port,
      server: server,
      timeout: timeout,
    );
    self._serve(path);
    SpbLog.info('loopback 回调监听已启动', {'port': self.port, 'path': path});
    return self;
  }

  /// 完整的回调 URI（作为授权请求的 `redirect_uri`）。
  String redirectUri({String path = defaultPath}) =>
      'http://127.0.0.1:$port$path';

  /// 等待授权回调，返回带 `code`/`state` 的回调 URL。
  ///
  /// 收到**任意**命中回调路径的请求即完成（含错误回调：
  /// `error=access_denied` 等），参数合法性（state 匹配、code 存在）由调用方
  /// 用 [OidcPkce.parseCallback] 判定——本类只负责「把浏览器送回来的 URL
  /// 拿到手」。
  ///
  /// 超时抛 [TimeoutException]。
  Future<Uri> wait() {
    _timer ??= Timer(timeout, () {
      if (!_completer.isCompleted) {
        _completer.completeError(
          TimeoutException('等待授权回调超时（${timeout.inMinutes} 分钟）', timeout),
        );
      }
      unawaited(close());
    });
    return _completer.future;
  }

  void _serve(String path) {
    _server.listen(
      (request) => unawaited(_handleRequest(request, path)),
      onError: (Object e) {
        // socket 层错误（如浏览器提前断开）：不影响已完成或超时的主流程。
        SpbLog.warn('loopback 监听 socket 错误', {'error': e.toString()});
      },
      cancelOnError: false,
    );
  }

  Future<void> _handleRequest(HttpRequest request, String path) async {
    // 只认回调路径：其他路径（扫描器、浏览器预取 favicon 等）一律 404，
    // 不让无关请求消费掉这次监听，也不因此关停监听。
    if (request.uri.path != path) {
      try {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } on Object catch (_) {
        // 连接已断开：无处可写。
      }
      return;
    }

    if (!_completer.isCompleted) _completer.complete(request.uri);

    // 给浏览器回提示页；无论是否首次命中都回（浏览器重试/双击时页面仍在）。
    try {
      await _respondDone(request);
    } on Object catch (e) {
      SpbLog.warn('回写回调提示页失败', {'error': e.toString()});
    }

    // 收到回调后立即关停：一次性监听，不留长期开着的端口。
    await close();
  }

  /// 给浏览器回一个最小提示页。
  ///
  /// 刻意不带 JS 自动关窗（跨浏览器不可靠）且不显示任何参数：
  /// 用户只需「回到应用」，token 永不出现在这里。
  Future<void> _respondDone(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.statusCode = HttpStatus.ok;
    request.response.write(
      '<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">'
      '<title>登录完成</title></head>'
      '<body style="font-family:sans-serif;text-align:center;padding-top:4em">'
      '<h2>登录已完成</h2>'
      '<p>请回到 Super PartyB 应用继续。</p>'
      '</body></html>',
    );
    await request.response.close();
  }

  /// 关停监听。幂等。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    try {
      await _server.close(force: true);
    } on Object catch (e) {
      SpbLog.warn('关闭 loopback 监听失败', {'error': e.toString()});
    }
  }
}

/// loopback 回调的固定部分（用于文档、断言与 IdP 注册）。
///
/// ## 为什么端口是「通配」而不是常量
///
/// 客户端每次登录都 bind 随机端口，因此 IdP 侧注册值**不含端口**：
/// `http://127.0.0.1/callback`。fosite 的 `isMatchingAsLoopback`
/// （`authorize_helper.go`）对 loopback 地址忽略端口比较，所以同一个注册值
/// 能匹配任意端口的回调——这正是 RFC 8252 §7.3 的要求。
///
/// ## 为什么 host 用字面量 `127.0.0.1` 而不是 `localhost`
///
/// RFC 8252 §7.3：`localhost` **NOT RECOMMENDED**——它可能解析到非回环地址，
/// 且 fosite 的匹配是「注册值与请求值 Hostname 相等」，用 `localhost` 注册
/// 就只能收 `localhost` 回调，两个拼写不能混用。
class LoopbackCallbackUri {
  const LoopbackCallbackUri._();

  /// 已注册（不含端口）的回调地址。
  static const String registeredRedirectUri = 'http://127.0.0.1/callback';

  /// 回调路径。
  static const String path = LoopbackRedirectServer.defaultPath;

  /// 判断 [uri] 是否为本应用的 loopback 回调。
  ///
  /// 同时比较 scheme + host + path：只看 scheme 会让
  /// `http://evil.com/callback?code=...` 这种伪造地址走进 token 交换逻辑。
  static bool matches(Uri uri) {
    if (uri.scheme != 'http') return false;
    if (uri.host != '127.0.0.1') return false;
    final p = uri.path;
    return p == path || p == '$path/';
  }

  /// 诊断用的安全描述（**不含任何参数值**）。
  @override
  String toString() => toStringOf();

  /// 静态诊断描述（同 [toString]，便于无实例场景使用）。
  static String toStringOf() => 'LoopbackCallbackUri($registeredRedirectUri)';
}

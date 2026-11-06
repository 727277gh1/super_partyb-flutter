import 'dart:async';

import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';

import 'oidc_client.dart';

/// 小程序扫码登录（App 内「微信一键」）。
///
/// ## 它解决什么
///
/// 手机上用户**无法扫自己屏幕上的码**，所以小程序码只服务跨设备场景（PC 显示、
/// 手机扫）。App 内要走通，链路是：
///
/// 1. `POST /qrcode-session?scheme=1` 创建 scene，并拿到可直接唤起小程序的
///    `weixin://dl/business/?t=...` 链接；
/// 2. App 打开该链接 → 微信小程序启动，用户在微信里确认；
/// 3. App 轮询 `GET /check/{scene}` 直到 `bound`（带 `X-Poll-Secret`）；
/// 4. `POST /exchange` 用 scene 换**标准 OIDC 授权码**（带 `poll_secret`）；
/// 5. 客户端走既有 `OidcClient.exchangeCode`（PKCE）换 token。
///
/// 第 4 步是关键：服务端不另发一套凭证，兑换出来的是 fosite 签发的普通授权码，
/// 因此 refresh/吊销/id_token 语义与浏览器登录完全一致。
///
/// ## 为什么轮询与兑换要分开
///
/// 轮询只回答「用户在微信里确认了没有」，**不携带任何凭证**（公开接口）；
/// 兑换是单次消费（scene 用完即废）。把发凭证的动作放在轮询接口上，等于给
/// 公开端点开一个发 token 的口子，审计与吊销都会退化。
class MiniProgramSession {
  const MiniProgramSession({
    required this.scene,
    required this.qrCodeUrl,
    this.schemeUrl,
    this.schemeError,
    this.expiresAt,
    this.shortCode,
    this.pollSecret,
  });

  /// 本次扫码会话的 scene（32 位十六进制）。
  final String scene;

  /// 小程序码图片（`data:image/png;base64,...`），跨设备场景用。
  final String qrCodeUrl;

  /// 可直接唤起小程序的链接（`weixin://dl/business/?t=...`）。
  ///
  /// 服务端按需生成（`?scheme=1`），失败时为空——此时只能降级到其他登录方式，
  /// 原因见 [schemeError]。
  final String? schemeUrl;

  /// 唤起链接生成失败的原因（可直接展示给用户）。
  final String? schemeError;

  final DateTime? expiresAt;

  /// 6 位短码（只有 `?code=1` 创建的会话才有，见 [MiniProgramLoginClient.createShortCodeSession]）。
  final MiniProgramShortCode? shortCode;

  /// 轮询/兑换密钥（服务端在创建时下发，见 id-provider 的 `generatePollSecret`）。
  ///
  /// 为什么必须有它：6 位短码同时是「人看的码」和「轮询/兑换的键」，而短码只有
  /// 30^6 种、预览端点还能被枚举。服务端把「知道短码」与「能轮询/兑换」用这个
  /// 密钥分开（RFC 8628 的 device_code / user_code 分工）：拿不到密钥的人即使
  /// 猜中 scene，轮询只会 403、兑换只会 403。
  ///
  /// 为 null 表示服务端没下发（旧版本服务端），此时按旧行为请求——不要自己编一个值。
  final String? pollSecret;

  /// 是否可以自己唤起微信（否则只能展示小程序码给另一台设备扫）。
  bool get canLaunchWeChat => schemeUrl != null && schemeUrl!.trim().isNotEmpty;

  /// 本次会话靠「让用户手输短码」完成（而不是唤起/扫码）。
  bool get isShortCode => shortCode != null;

  @override
  String toString() =>
      'MiniProgramSession(scene: $scene, canLaunch: $canLaunchWeChat)';
}

/// 6 位登录码（`A3F-9K2`）。
///
/// ## 为什么需要它
///
/// 个人主体小程序拿不到 URL Scheme 权限（`85407`），OpenSDK 也没配时，
/// App 内就没有任何办法把用户送进小程序。此时唯一还剩的通道是**让用户自己
/// 打开小程序、手输一个码**——零资质、零费用，见 id-provider#18。
///
/// ## 为什么要展示 `displayCode` 而不是 `scene`
///
/// `scene` 是服务端会话键（短码形态下两者同值），`displayCode` 是分组形态
/// `A3F-9K2`：分组让人能逐段核对，长串裸字符容易抄错一位而毫无察觉。
class MiniProgramShortCode {
  const MiniProgramShortCode({
    required this.scene,
    required this.displayCode,
    required this.expiresInSeconds,
  });

  /// 会话键（与 [MiniProgramSession.scene] 同值，兑换时用它）。
  final String scene;

  /// 展示形态：`A3F-9K2`。
  final String displayCode;

  /// 剩余有效秒数（服务端 TTL，通常 300）。
  final int expiresInSeconds;

  /// 剩余有效时长（倒计时展示用）。
  Duration get ttl => Duration(seconds: expiresInSeconds);

  @override
  String toString() => 'MiniProgramShortCode($displayCode, ${ttl.inSeconds}s)';
}

/// 轮询结果。
enum MiniProgramPollState {
  /// 用户还没在微信里确认。
  pending,

  /// 已完成（可以兑换授权码）。
  done,

  /// 会话过期或已被使用（需要重新发起）。
  expired,
}

/// 小程序扫码登录的 API 客户端。
class MiniProgramLoginClient {
  MiniProgramLoginClient({
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    Dio? dio,
  }) : _dio = dio ?? Dio(BaseOptions(responseType: ResponseType.json));

  /// IdP issuer（含 basePath，例如 `https://tbcc.atjog.com/idp`）。
  final Uri issuer;

  /// OIDC public client id（兑换出的授权码绑定它）。
  final String clientId;

  /// 兑换授权码时声明的 redirect_uri，必须与 client 注册值一致
  /// （`partyb://oidc/callback` 或 claimed HTTPS 形态）。
  final String redirectUri;

  final Dio _dio;

  /// 小程序登录端点根路径：`{issuer}/api/v1/bindings/mini-program`。
  ///
  /// 从 issuer 推导而非写死域名：staging / 双栈（tbcc / tbcc6）下 issuer 变了
  /// 端点就该跟着变，写死会让某个构建静默打到错误的环境。
  Uri get endpointBase {
    final basePath = issuer.path.replaceAll(RegExp(r'/+$'), '');
    return issuer.replace(path: '$basePath/api/v1/bindings/mini-program');
  }

  /// 创建扫码会话（[withScheme] 为 true 时顺带生成可直接唤起小程序的链接）。
  Future<MiniProgramSession> createSession({bool withScheme = true}) async {
    // poll_secret=1 声明「我认识轮询密钥」：服务端会下发 pollSecret，之后
    // 轮询与兑换都必须出示。不带它服务端会退回旧行为（会话可被枚举者利用），
    // 所以这个参数是安全属性，不是可选优化。
    final uri = endpointBase.replace(
      path: '${endpointBase.path}/qrcode-session',
      queryParameters: withScheme
          ? {'scheme': '1', 'poll_secret': '1'}
          : {'poll_secret': '1'},
    );

    // 必须声明 Content-Type：网关对**无 Content-Type 的 POST** 直接 400
    // （`Content-Type header is required for POST requests`），而这条请求本来
    // 就没有请求体。实测踩过：不声明时前端只看到「小程序登录失败」，真正的
    // 拒绝发生在网关。
    //
    // 只设 header 不加空 body：加 `data: {}` 会让请求多出一个 `{}` 载荷，
    // 服务端不读它，却让「这条 POST 没有请求体」这个事实变得含糊。
    final res = await _request(
      () => _dio.post<dynamic>(
        uri.toString(),
        options: Options(contentType: Headers.jsonContentType),
      ),
    );
    final data = _asMap(res.data);
    final scene = _str(data['scene']);
    if (scene == null) {
      throw const AuthError('小程序登录会话创建失败（响应缺少 scene）');
    }
    return MiniProgramSession(
      scene: scene,
      qrCodeUrl: _str(data['qrCodeUrl']) ?? '',
      schemeUrl: _str(data['schemeUrl']),
      schemeError: _str(data['schemeError']),
      expiresAt: DateTime.tryParse(_str(data['expiresAt']) ?? ''),
      pollSecret: _str(data['pollSecret']),
    );
  }

  /// 创建「手输 6 位码」会话（不生成小程序码、不生成 URL Scheme）。
  ///
  /// 这条路径服务的是「小程序唤不起来」的场景：服务端只发一个 6 位码，用户
  /// 自己打开小程序输入它。返回的 [MiniProgramSession.scene] 与扫码路径同值
  /// 语义，后续 [poll] / [exchange] 完全复用，不需要第二套状态机。
  Future<MiniProgramSession> createShortCodeSession() async {
    final uri = endpointBase.replace(
      path: '${endpointBase.path}/qrcode-session',
      queryParameters: {'code': '1', 'poll_secret': '1'},
    );
    final res = await _request(
      () => _dio.post<dynamic>(
        uri.toString(),
        options: Options(contentType: Headers.jsonContentType),
      ),
    );
    final data = _asMap(res.data);
    final scene = _str(data['scene']);
    if (scene == null) {
      throw const AuthError('登录码创建失败（响应缺少 scene）');
    }
    final display =
        _str(data['displayCode']) ?? _str(data['userCode']) ?? scene;
    return MiniProgramSession(
      scene: scene,
      // 短码路径不产出小程序码；留空而不是塞占位串，避免 UI 误当成可展示的图。
      qrCodeUrl: '',
      expiresAt: DateTime.tryParse(_str(data['expiresAt']) ?? ''),
      shortCode: MiniProgramShortCode(
        scene: scene,
        displayCode: display,
        expiresInSeconds: _int(data['expiresInSeconds']) ?? 300,
      ),
      pollSecret: _str(data['pollSecret']),
    );
  }

  /// 轮询扫码状态（不携带用户凭证，但要带轮询密钥）。
  ///
  /// 密钥放请求头而不是 query：URL 会进网关/反代日志与浏览器历史，而密钥是
  /// 「能换 token 的那把钥匙」的前置，不该出现在日志里。
  Future<MiniProgramPollState> poll(String scene, {String? pollSecret}) async {
    final uri = endpointBase.replace(path: '${endpointBase.path}/check/$scene');
    final res = await _request(
      () => _dio.get<dynamic>(
        uri.toString(),
        options: Options(headers: _pollSecretHeader(pollSecret)),
      ),
    );
    final data = _asMap(res.data);
    if (data['bound'] == true) return MiniProgramPollState.done;
    if (data['expired'] == true) return MiniProgramPollState.expired;
    return MiniProgramPollState.pending;
  }

  /// 用已完成扫码的 scene 兑换 OIDC 授权码。
  ///
  /// 返回的 code 交给 `OidcClient.exchangeCode`（同一个 [pkce]）换 token。
  Future<String> exchange({
    required String scene,
    required PkcePair pkce,
    required String state,
    String? pollSecret,
  }) async {
    final uri = endpointBase.replace(path: '${endpointBase.path}/exchange');
    final res = await _request(
      () => _dio.post<dynamic>(
        uri.toString(),
        data: {
          'scene': scene,
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'state': state,
          'code_challenge': pkce.challenge,
          'code_challenge_method': 'S256',
          if (pollSecret != null && pollSecret.isNotEmpty)
            'poll_secret': pollSecret,
        },
      ),
    );
    final code = _str(_asMap(res.data)['code']);
    if (code == null) {
      throw const AuthError('授权码兑换失败（响应缺少 code）');
    }
    return code;
  }

  /// 用**反向登录码**（小程序出码、本设备输码）兑换 OIDC 授权码。
  ///
  /// ## 与 [exchange] 的区别
  ///
  /// - [exchange] 消费的是「小程序已确认的 scene」（正向：App 出码 → 小程序确认）；
  /// - 本方法消费的是「小程序已登录后自己发出的 8 位码」（反向），
  ///   谁拿到码谁就能兑换，所以服务端做了 8 位长度、2 分钟 TTL、单次消费、
  ///   同码错 5 次作废、按来源限流。
  ///
  /// 两条路径**端点与存储都隔离**：反向码进 `/exchange` 会 404，正向 scene 进
  /// `/handoff/redeem` 会 400（格式），所以这里不会误消费别的会话。
  ///
  /// 返回的 code 交给 `OidcClient.exchangeCode`（同一个 [pkce]）换 token，
  /// 与浏览器/正向登录完全一致。
  Future<String> redeemHandoffCode({
    required String code,
    required PkcePair pkce,
    required String state,
  }) async {
    final uri = endpointBase.replace(
      path: '${endpointBase.path}/handoff/redeem',
    );
    final res = await _request(
      handoff: true,
      () => _dio.post<dynamic>(
        uri.toString(),
        data: {
          // 字段名与正向 exchange 一致（服务端复用同一个请求结构），语义是
          // 「用户手抄的码」。带不带横线都行：服务端会归一化。
          'scene': code,
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'state': state,
          'code_challenge': pkce.challenge,
          'code_challenge_method': 'S256',
        },
      ),
    );
    final authCode = _str(_asMap(res.data)['code']);
    if (authCode == null) {
      throw const AuthError('登录码兑换失败（响应缺少 code）');
    }
    return authCode;
  }

  /// 统一错误映射：把服务端的 `error` 码翻成用户能读懂的原因。
  Future<Response<dynamic>> _request(
    Future<Response<dynamic>> Function() send, {
    bool handoff = false,
  }) async {
    try {
      return await send();
    } on DioException catch (e) {
      throw AuthError(_messageFor(e, handoff: handoff));
    }
  }

  String _messageFor(DioException e, {bool handoff = false}) {
    final data = e.response?.data;
    final code = data is Map ? _str(data['error']) : null;
    switch (code) {
      case 'rate_limited':
        // 短码只有 6 位，服务端按来源限流（10 次/10 分钟）。这条文案必须
        // 说明「过一会儿再试」，否则用户会以为是自己码抄错了。
        return '尝试次数过多，请稍后再试';
      case 'not_found':
      case 'expired':
      case 'already_used':
        // 反向码的语义完全不同：码是持有即授权的凭据，`not_found` 意味着
        // 用户抄错了或已被别人用掉，出路是「核对」或「回小程序重新出码」，
        // 而不是「重新发起 App 侧会话」（那是正向的说法）。
        if (handoff) {
          return code == 'expired'
              ? '登录码已过期，请在小程序里重新生成'
              : '登录码无效或已被使用，请核对后重新输入';
        }
        // 短码确认侧（小程序）才会拿到这三个码；App 侧只在兑换过期 scene 时
        // 可能碰到，统一提示重新发起。
        return '登录码已失效，请重新发起';
      case 'too_many_attempts':
        // 同一个码错够次数就被作废：不能再让用户继续试，只能重新出码。
        return '这个登录码尝试次数过多已作废，请在小程序里重新生成';
      case 'poll_secret_required':
      case 'poll_secret_invalid':
        // 服务端要求出示轮询密钥而这次请求没带/带错了。对用户来说等价于
        // 「这次登录会话不能再用」，只能重新发起——但对开发者是明确信号：
        // 客户端漏传了 MiniProgramSession.pollSecret。
        return '登录会话已失效，请重新发起';
      case 'scene_pending':
        return '微信里还没确认，请在小程序中完成登录';
      case 'scene_expired':
        return '二维码已过期，请重新发起';
      case 'scene_not_found':
        return '登录会话已失效，请重新发起';
      case 'invalid_request':
        return '登录参数校验失败（客户端配置与 IdP 注册不一致）';
      case 'bad_request':
        return '请求参数有误，请重试';
      case 'unavailable':
        return '服务端未启用小程序登录';
    }
    // 没有结构化错误（网络失败、网关 5xx）时给出可操作的信息。
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return '无法连接认证服务，请检查网络后重试';
    }
    return '小程序登录失败：${e.message ?? e.type.name}';
  }

  /// 轮询密钥的请求头（为空时不加，保持旧服务端兼容）。
  Map<String, String> _pollSecretHeader(String? secret) {
    if (secret == null || secret.isEmpty) return const <String, String>{};
    return <String, String>{'X-Poll-Secret': secret};
  }

  Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.map((k, v) => MapEntry(k.toString(), v));
    return const {};
  }

  int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  String? _str(Object? v) {
    if (v is String && v.trim().isNotEmpty) return v;
    return null;
  }
}

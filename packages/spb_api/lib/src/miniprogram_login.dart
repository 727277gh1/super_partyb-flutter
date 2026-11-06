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
/// 3. App 轮询 `GET /check/{scene}` 直到 `bound`；
/// 4. `POST /exchange` 用 scene 换**标准 OIDC 授权码**；
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

  /// 是否可以自己唤起微信（否则只能展示小程序码给另一台设备扫）。
  bool get canLaunchWeChat => schemeUrl != null && schemeUrl!.trim().isNotEmpty;

  @override
  String toString() =>
      'MiniProgramSession(scene: $scene, canLaunch: $canLaunchWeChat)';
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
    final uri = endpointBase.replace(
      path: '${endpointBase.path}/qrcode-session',
      queryParameters: withScheme ? {'scheme': '1'} : null,
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
    );
  }

  /// 轮询扫码状态（不携带凭证）。
  Future<MiniProgramPollState> poll(String scene) async {
    final uri = endpointBase.replace(path: '${endpointBase.path}/check/$scene');
    final res = await _request(() => _dio.get<dynamic>(uri.toString()));
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
        },
      ),
    );
    final code = _str(_asMap(res.data)['code']);
    if (code == null) {
      throw const AuthError('授权码兑换失败（响应缺少 code）');
    }
    return code;
  }

  /// 统一错误映射：把服务端的 `error` 码翻成用户能读懂的原因。
  Future<Response<dynamic>> _request(
    Future<Response<dynamic>> Function() send,
  ) async {
    try {
      return await send();
    } on DioException catch (e) {
      throw AuthError(_messageFor(e));
    }
  }

  String _messageFor(DioException e) {
    final data = e.response?.data;
    final code = data is Map ? _str(data['error']) : null;
    switch (code) {
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

  Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.map((k, v) => MapEntry(k.toString(), v));
    return const {};
  }

  String? _str(Object? v) {
    if (v is String && v.trim().isNotEmpty) return v;
    return null;
  }
}

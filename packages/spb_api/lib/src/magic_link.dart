import 'dart:async';

import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';

import 'oidc_client.dart';

/// 邮箱 magic link 登录（「用邮件登录」）。
///
/// ## 它解决什么
///
/// 另外两条入口都有摩擦：系统浏览器 SSO 在移动端至少 3 次跳转、桌面端还要靠
/// 「粘贴导入会话」补最后一公里；微信一键要求装微信且受开放平台审核约束。
/// magic link 把登录变成「输邮箱 → 点邮件里的链接 → 回应用已登录」。
///
/// ## 链路（创建 → 确认 → 轮询 → 兑换）
///
/// 1. `POST {issuer}/api/v1/auth/magic-link {email}` → 202 + `requestId`
///    （**不区分邮箱是否存在**，否则这个端点就是账号枚举工具）；
/// 2. 用户在浏览器/邮件客户端点链接 → IdP 落地页 → 点「确认登录」（POST）；
/// 3. 客户端轮询 `GET .../check?request_id=`，只回答 `pending|confirmed|expired`；
/// 4. `POST .../exchange` 用 requestId 换**标准 OIDC 授权码**（单次消费）；
/// 5. 客户端走既有 `OidcClient.exchangeCode`（PKCE）换 token。
///
/// 第 4 步是关键：服务端不另发一套凭证，兑换出的是 fosite 签发的普通授权码，
/// 因此 refresh / 吊销 / id_token 语义与浏览器登录完全一致。
///
/// ## 为什么轮询与兑换分开
///
/// 轮询是公开端点且被高频调用，**不能携带任何凭证**；兑换是单次消费。
/// 把发凭证的动作放在轮询上，等于给公开端点开一个发 token 的口子。
class MagicLinkRequest {
  const MagicLinkRequest({required this.requestId, this.expiresAt});

  /// 本次登录请求的标识（轮询与兑换都用它）。
  ///
  /// 它**不是凭证**：拿到它也无法登录（兑换还要 PKCE verifier 与已确认状态）。
  final String requestId;

  final DateTime? expiresAt;

  @override
  String toString() => 'MagicLinkRequest(requestId: $requestId)';
}

/// 轮询结果。
enum MagicLinkPollState {
  /// 用户还没在邮件里点「确认登录」。
  pending,

  /// 已确认（可以兑换授权码）。
  confirmed,

  /// 链接过期或请求已被使用（需要重新发起）。
  expired,
}

/// magic link 登录的 API 客户端。
class MagicLinkClient {
  MagicLinkClient({
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    Dio? dio,
  }) : _dio = dio ?? Dio(BaseOptions(responseType: ResponseType.json));

  /// IdP issuer（含 basePath，例如 `https://app.example.com/idp`）。
  final Uri issuer;

  /// OIDC public client id（兑换出的授权码绑定它）。
  final String clientId;

  /// 兑换授权码时声明的 redirect_uri，必须与 client 注册值一致
  /// （`partyb://oidc/callback`、claimed HTTPS 形态，或桌面 loopback）。
  final String redirectUri;

  final Dio _dio;

  /// 邮箱登录端点根路径：`{issuer}/api/v1/auth/magic-link`。
  ///
  /// 从 issuer 推导而非写死域名：staging / 双栈（tbcc / tbcc6）下 issuer 变了
  /// 端点就该跟着变，写死会让某个构建静默打到错误的环境。
  Uri get endpointBase {
    final basePath = issuer.path.replaceAll(RegExp(r'/+$'), '');
    return issuer.replace(path: '$basePath/api/v1/auth/magic-link');
  }

  /// 受理一次登录请求（服务端发信）。
  ///
  /// 返回的 `requestId` 用于轮询与兑换。**响应与邮箱是否存在无关**——调用方
  /// 不该据此推断账号是否存在。
  Future<MagicLinkRequest> request(String email) async {
    final res = await _request(
      () => _dio.post<dynamic>(endpointBase.toString(), data: {'email': email}),
    );
    final data = _asMap(res.data);
    final requestId = _str(data['requestId']);
    if (requestId == null) {
      throw const AuthError('登录请求受理失败（响应缺少 requestId）');
    }
    return MagicLinkRequest(
      requestId: requestId,
      expiresAt: DateTime.tryParse(_str(data['expiresAt']) ?? ''),
    );
  }

  /// 轮询确认状态（不携带凭证）。
  Future<MagicLinkPollState> poll(String requestId) async {
    final uri = endpointBase.replace(
      path: '${endpointBase.path}/check',
      queryParameters: {'request_id': requestId},
    );
    final res = await _request(() => _dio.get<dynamic>(uri.toString()));
    switch (_str(_asMap(res.data)['status'])) {
      case 'confirmed':
        return MagicLinkPollState.confirmed;
      case 'pending':
        return MagicLinkPollState.pending;
      default:
        // 未知状态一律按过期处理：继续等下去只会让用户卡在等待态。
        return MagicLinkPollState.expired;
    }
  }

  /// 用已确认的 requestId 兑换 OIDC 授权码。
  ///
  /// 返回的 code 交给 `OidcClient.exchangeCode`（同一个 [pkce]）换 token。
  Future<String> exchange({
    required String requestId,
    required PkcePair pkce,
    required String state,
  }) async {
    final uri = endpointBase.replace(path: '${endpointBase.path}/exchange');
    final res = await _request(
      () => _dio.post<dynamic>(
        uri.toString(),
        data: {
          'request_id': requestId,
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
  ///
  /// 服务端有两套错误体：标准 AppError（`validation_error` / `conflict` /
  /// `service_unavailable`，带可展示的 `message`）与 exchange 的自定义码
  /// （`request_pending` 等）。两套都要认，否则用户只会看到「失败」。
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
    final serverMessage = data is Map ? _str(data['message']) : null;

    switch (code) {
      case 'request_pending':
        return '还没有在邮件里确认，请点开邮件中的链接并点击「确认登录」';
      case 'request_expired':
        return '登录链接已过期，请重新发起';
      case 'request_not_found':
        return '登录请求已失效，请重新发起';
      case 'invalid_request':
        return '登录参数校验失败（客户端配置与 IdP 注册不一致）';
      case 'bad_request':
        return '请求参数有误，请重试';
      case 'unavailable':
      case 'service_unavailable':
        return '服务端暂时无法发送登录邮件，请稍后重试';
      case 'validation_error':
      case 'conflict':
        // 这两类服务端给了可读原因（邮箱格式无效 / 发送过于频繁），直接透传。
        return serverMessage ?? '请求未被接受，请检查输入后重试';
    }

    // 没有结构化错误（网络失败、网关 5xx）时给出可操作的信息。
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return '无法连接认证服务，请检查网络后重试';
    }
    return serverMessage ?? '邮箱登录失败：${e.message ?? e.type.name}';
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

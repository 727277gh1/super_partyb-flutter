import 'dart:async';

import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

/// 认证头注入器 + 401/403 归一化 + 刷新后重放。
///
/// ## 认证模型（重要）
///
/// 生产链路是：**客户端 → api-gateway（OIDC 认证）→ 注入 `X-User-ID` → Go API**。
/// 因此客户端**不解析 JWT、不申请 API Key**，只需携带会话凭证（Cookie / OIDC token），
/// 由网关完成认证并注入身份头。
///
/// 本地开发可绕过网关直连 Go API（`AUTH_MODE=header`），此时需要自行提供
/// `X-User-ID`——本类通过 [userHeaderOverride] 支持这种开发态。
///
/// ⚠️ **绝不缓存 user_id 到持久化存储并当作身份真源**：它是网关注入的结果，
/// 客户端侧的值只用于拼 URL 路径（`/users/:user_id/chat/*`）。
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.tokenProvider,
    this.userHeaderOverride,
    this.onUnauthorized,
    this.onSessionExpired,
  });

  /// 异步获取当前会话凭证（OIDC access token / session cookie）。
  ///
  /// 用回调而非直接持有 token：token 会过期并刷新，持有快照会用到陈旧值。
  /// 通常由 `SessionManager.currentAccessToken` 实现（内含过期前刷新）。
  final Future<String?> Function() tokenProvider;

  /// 开发态直连 Go API 时手工指定的 `X-User-ID`。
  ///
  /// **生产必须为 null**——若生产也设置，等于允许客户端自选身份，
  /// 会绕过网关的认证。网关模式下这个头由网关覆盖写入。
  final String? userHeaderOverride;

  /// 401 时的刷新回调。返回 true 表示已刷新，可重放原请求。
  ///
  /// 由 `SessionManager.refresh` 实现。为 null 时不做刷新，401 直接归一化为
  /// [AuthError]。
  final Future<bool> Function()? onUnauthorized;

  /// 会话**确定**失效时的通知（401 且刷新重放也没救回来）。
  ///
  /// ## 为什么需要它（此前这个回调不存在，于是「跳登录页」无处发生）
  ///
  /// 本拦截器只把 401 归一化成 [AuthError] 抛给调用方，而**各页面**拿到它
  /// 只翻成一句 SnackBar 文案（如「登录已过期，请重新登录」），没有任何一处
  /// 把认证状态推进到未登录。结果是：会话真的过期后，用户卡在首页/对话页，
  /// 只能手动进设置页点「退出登录」才能回登录页。
  ///
  /// 装配层（两端 `providers.dart`）把它接到
  /// `authStateProvider.notifier.markUnauthenticated`，由路由守卫做**唯一一次**
  /// 重定向（`resolveAuthRedirect`）。
  ///
  /// ## 三个约束（改之前必读）
  ///
  /// 1. **只在 401 触发，403 绝不触发**：403 是「已认证但无权限」，把它当登出
  ///    会让「点了一个没权限的按钮」直接把用户踢出登录。
  /// 2. **只在「刷新也失败」之后触发**：`SessionManager._doRefresh` 明确保留
  ///    了「临时网络故障不该让用户登出」这一取向。唯一可信的信号是
  ///    「刷新过了，服务端仍然 401」。
  /// 3. **不在这里导航**：同一时刻可能有多个请求同时 401，导航副作用会互相
  ///    打架。回调只改状态，重定向交给路由守卫。
  final void Function(String message)? onSessionExpired;

  /// 重放请求用的 Dio。
  ///
  /// ## 为什么是可变字段而非构造参数
  ///
  /// 它必须是**同一个** Dio（否则会丢掉连接池与其余拦截器），而本拦截器又是
  /// 该 Dio 的构造参数之一——直接传参会形成循环。故由 `createDio` 的调用方在
  /// 构造后立即回填（见两端 `providers.dart`）：
  ///
  /// ```dart
  /// final auth = AuthInterceptor(...);
  /// final dio = createDio(interceptors: [auth]);
  /// auth.replayDio = dio;
  /// ```
  ///
  /// 为 null 时（如单测直接构造拦截器）不重放，401 归一化为 [AuthError]。
  Dio? replayDio;

  /// 标记「已重放过一次」，防止刷新后仍 401 造成无限循环。
  static const String _retriedKey = 'spb_auth_retried';

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final token = await tokenProvider();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      final override = userHeaderOverride;
      if (override != null && override.isNotEmpty) {
        options.headers['X-User-ID'] = override;
      }
      handler.next(options);
    } catch (e) {
      // 取 token 失败不应让请求静默消失——放行让服务端返回 401，
      // 上层据此触发重新登录，比在此处吞掉错误更可诊断。
      SpbLog.warn('获取认证凭证失败，请求将以匿名身份发出', {'error': e.toString()});
      handler.next(options);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;

    // 只有 401 值得刷新：403 是「已认证但无权限」，刷新 token 也变不出权限。
    if (status == 401) {
      final refreshed = await _tryRefreshAndReplay(err, handler);
      if (refreshed) return;
      SpbLog.warn('收到 401，会话凭证可能已失效');
      // 通知装配层把认证状态推进到未登录（由路由守卫做唯一一次重定向）。
      //
      // 不在此处导航：拦截器不应有导航副作用（可能同时多个请求触发）。
      // 也不在此处清凭证：401 可能是网关侧临时问题，清掉会让用户丢掉
      // refresh_token（见 `markUnauthenticated` 的说明）。
      //
      // ## 为什么带 `_retriedKey` 守卫（否则会通知两次）
      //
      // 重放请求也是**经过本拦截器**的：它在内部再走一次 `onError`，那时
      // `_tryRefreshAndReplay` 因 `_retriedKey` 直接返回 false。若这里不判，
      // 「刷新成功但重放仍 401」会先由重放那次通知一遍，再由下面
      // `_tryRefreshAndReplay` 的 catch 通知一遍（实测：回调被调 2 次）。
      // 两次通知虽幂等（状态一样），但会污染日志与测试断言。
      if (err.requestOptions.extra[_retriedKey] != true) {
        onSessionExpired?.call('会话已失效，请重新登录');
      }
    }

    handler.next(_normalizeAuthError(err));
  }

  /// 刷新凭证并重放原请求。返回 true 表示已 resolve（调用方不应再继续处理）。
  Future<bool> _tryRefreshAndReplay(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final refresh = onUnauthorized;
    final dio = replayDio;
    if (refresh == null || dio == null) return false;
    if (err.requestOptions.extra[_retriedKey] == true) return false;

    bool refreshed;
    try {
      refreshed = await refresh();
    } catch (e) {
      SpbLog.warn('刷新会话凭证时异常', {'error': e.toString()});
      return false;
    }
    if (!refreshed) return false;

    // 重放：复制原请求并把新 token 交给 onRequest 重新注入。
    // 打上标记避免「刷新成功但服务端仍 401」时无限循环。
    final options = err.requestOptions
      ..extra[_retriedKey] = true
      // 清掉旧 Authorization，否则 onRequest 覆盖前会先带上过期值。
      ..headers.remove('Authorization');

    try {
      final response = await dio.fetch<dynamic>(options);
      SpbLog.debug('401 后刷新凭证并重放成功', {'path': options.path});
      handler.resolve(response);
      return true;
    } on DioException catch (e) {
      // 重放也失败：按重放响应归一化（它带着更准确的状态码）。
      //
      // 若重放仍是 401，说明**刷新成功但新凭证依然被拒**（账号被禁、会话被
      // 服务端撤销）。这也是确定的会话失效，故同样要通知装配层；否则这条
      // 路径（刷新成功但重放 401）会静默停在旧页面上。
      final normalized = _normalizeAuthError(e);
      final mapped = normalized.error;
      if (mapped is AuthError && mapped.isUnauthorized) {
        SpbLog.warn('刷新后重放仍 401，会话确定失效');
        onSessionExpired?.call(mapped.message);
      }
      handler.next(normalized);
      return true;
    }
  }

  /// 把 401/403 归一化为 [AuthError]。
  ///
  /// ## 为什么不复用 [HttpError]
  ///
  /// 上层对 401 的处置是「跳登录页」而非「重试请求」。若沿用 `HttpError`，
  /// UI 只能靠 `statusCode == 401` 判断；归一化成 [AuthError] 后，
  /// 监听一种类型即可（见 `packages/spb_core/lib/src/errors.dart` 的说明）。
  static DioException _normalizeAuthError(DioException err) {
    final status = err.response?.statusCode;
    if (status != 401 && status != 403) return err;

    final mapped = AuthError(
      status == 401 ? '会话已失效，请重新登录' : '没有权限执行该操作',
      statusCode: status,
      cause: err,
    );
    return DioException(
      requestOptions: err.requestOptions,
      response: err.response,
      type: err.type,
      error: mapped,
      stackTrace: err.stackTrace,
    );
  }
}

/// 把 dio 异常统一转成 [SpbError]，使上层只处理一种错误类型。
SpbError mapDioError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return NetworkError(
        '网络请求失败：${e.message ?? e.type.name}',
        cause: e,
        retryable: true,
      );
    case DioExceptionType.cancel:
      return NetworkError('请求已取消', cause: e, retryable: false);
    case DioExceptionType.badCertificate:
      return NetworkError('TLS 证书校验失败', cause: e, retryable: false);
    case DioExceptionType.transformTimeout:
      // 响应体转换超时：本地处理慢，重试通常无用但无害。
      return NetworkError('响应处理超时', cause: e, retryable: false);
    case DioExceptionType.badResponse:
      final status = e.response?.statusCode ?? 0;
      // 401/403 是「凭证问题」而非「请求问题」：归为 AuthError 让上层能区分
      // 「该重新登录」与「该重试」。否则 UI 会把会话过期显示成「HTTP 401」。
      if (status == 401) {
        return AuthError('会话已失效，请重新登录', statusCode: 401, cause: e);
      }
      if (status == 403) {
        return AuthError('没有权限执行该操作', statusCode: 403, cause: e);
      }
      return HttpError(
        status,
        'HTTP $status',
        body: _bodyPreview(e.response?.data),
        cause: e,
      );
    case DioExceptionType.unknown:
      // 响应已到达但解析失败时会落到这里，归类为解析错误。
      if (e.response != null) {
        return ParseError('响应解析失败', cause: e);
      }
      return NetworkError('未知网络错误：${e.message}', cause: e);
  }
}

String? _bodyPreview(Object? data) {
  if (data == null) return null;
  final s = data is String ? data : data.toString();
  // 截断避免把整页 HTML 错误塞进日志/UI。
  return s.length > 500 ? '${s.substring(0, 500)}…' : s;
}

/// 便捷方法：从响应体里取 `items` 数组（Go API 的裸 JSON 约定）。
///
/// 前端（webapp）用 `requestJson` + `unwrapItems` 适配，此处等价。
/// 见 super_partyb AGENTS.md「API 响应结构」：Go API 返回裸 JSON
/// （如 `{items:[...]}`），不再用 Python 的 `{success,data,error}` 包装。
List<T> unwrapItems<T>(
  Object? json,
  T Function(Map<String, dynamic>) fromItem,
) => ListResponse<T>.fromJson(json, fromItem).items;

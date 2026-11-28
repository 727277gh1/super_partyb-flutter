import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// 用户级支持工单 API（`/me/support/cases`）。
///
/// 归属由 Go API 从已认证身份确定；客户端不得传 user id。写操作返回 HTTP 202，
/// 表示本地已持久化并进入 outbox，不代表 service-ops 已受理。
class SupportApi {
  SupportApi(this._dio);

  final Dio _dio;

  /// `GET /me/support/cases` → `{items: [...]}`。
  Future<List<SupportCase>> list() async {
    final response = await _get('/me/support/cases');
    final items = _asMap(response)['items'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) SupportCase.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  /// `POST /me/support/cases` → HTTP 202 + 工单对象。
  Future<SupportCase> submit({
    required String subject,
    required String description,
  }) async {
    final response = await _post(
      '/me/support/cases',
      body: {'subject': subject, 'description': description},
    );
    return SupportCase.fromJson(_asMap(response));
  }

  Future<Object?> _get(String path) async {
    try {
      return _unwrap(await _dio.get<dynamic>(path));
    } on DioException catch (error) {
      throw _toSpbError(error);
    }
  }

  Future<Object?> _post(
    String path, {
    required Map<String, Object?> body,
  }) async {
    try {
      return _unwrap(await _dio.post<dynamic>(path, data: body));
    } on DioException catch (error) {
      throw _toSpbError(error);
    }
  }

  Object? _unwrap(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw HttpError(
        status,
        'HTTP $status',
        body: _bodyPreview(response.data),
      );
    }
    return response.data;
  }

  SpbError _toSpbError(DioException error) {
    final inner = error.error;
    if (inner is SpbError) return inner;
    return mapDioError(error);
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }

  static String? _bodyPreview(Object? data) {
    if (data == null) return null;
    final value = data is String ? data : data.toString();
    return value.length > 500 ? '${value.substring(0, 500)}…' : value;
  }
}

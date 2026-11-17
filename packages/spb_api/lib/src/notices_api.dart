import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// 站内通知 API（`/me/notices`）。
///
/// ## 为什么单独一个类
///
/// 这组端点是**用户级**的（`/me/*`），不属于任何 group，与 `ChatApi` 的对话语义
/// 无关。放进 `ChatApi` 会让「对话」这个类继续膨胀，也让后台 isolate 的装配
/// 多带一堆无关方法。
///
/// ## 与确认卡端点（`/chat/confirmations`）的分工
///
/// - `/chat/confirmations` 返回**卡片**：有状态机，10 分钟后从列表里消失。
/// - `/me/notices` 返回**通知**：持久事实，卡片过期后仍然在，带已读状态。
///
/// 客户端通知中心与后台通知都应该读后者——读前者会在 15 分钟轮询周期里
/// 永远拉到已过期的卡（卡片寿命 10 分钟）。
///
/// ## 每个方法都显式判状态码
///
/// `createDio` 的 `validateStatus` 放行 <500（401/403 除外），故 4xx **不会**抛
/// `DioException`。不判的话 `{"error":"通知暂不可用"}` 会被当成成功响应，再被
/// 解析成「字段全空的对象」——不报错、不抛异常，UI 表现为「通知莫名是空的」。
/// 与 `MiniappApi` / `ChatApi` / `UfsApi` 同一约定。
class NoticesApi {
  NoticesApi(this._dio);

  final Dio _dio;

  /// `GET /me/notices?limit=&unread_only=1`
  ///
  /// 返回 `{notices: [...], unread: N}`。服务端在未读数查询失败时会把 `unread`
  /// 降级为 0 而不是整体 503，故 [NoticeListResult.unread] 可能偏小——不要用它
  /// 做「有没有新通知」的唯一依据，判据应是列表内容本身。
  Future<NoticeListResult> list({
    int limit = 50,
    bool unreadOnly = false,
  }) async {
    final res = await _get(
      '/me/notices',
      query: {'limit': limit, if (unreadOnly) 'unread_only': '1'},
    );
    final map = _asMap(res);
    final raw = map['notices'];
    final notices = <Notice>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) notices.add(Notice.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return NoticeListResult(
      notices: notices,
      unread: map['unread'] is num ? (map['unread'] as num).toInt() : 0,
    );
  }

  /// `GET /me/notices/unread-count` → `{unread: N}`
  ///
  /// 后台轮询的第一跳：一个整数，流量远小于拉整页列表。有增量才拉列表。
  Future<int> unreadCount() async {
    final res = await _get('/me/notices/unread-count');
    final v = _asMap(res)['unread'];
    return v is num ? v.toInt() : 0;
  }

  /// `POST /me/notices/read`，body `{ids: [...]}` 或 `{all: true}`。
  ///
  /// ## 404 不当错误
  ///
  /// 服务端在**全部** id 都未命中时返回 404（含「不是你的通知」，两者同码以免
  /// 泄露存在性）。对客户端来说这不是失败，而是「这批 id 已经失效了」——典型
  /// 来源是保留期清理与本地缓存过期。所以这里把 404 归一成
  /// `updated: 0, missing: ids`，由调用方下一轮自然重试，**不要弹错误提示**。
  ///
  /// 部分成功时服务端返回 200 + `{updated, missing}`，[MarkReadResult.missing]
  /// 同样只做诊断用途。
  Future<MarkReadResult> markRead({
    List<String> ids = const [],
    bool all = false,
  }) async {
    if (!all && ids.isEmpty) {
      throw const HttpError(400, '缺少通知 id（或传 all=true）');
    }
    try {
      final res = await _post(
        '/me/notices/read',
        body: all ? {'all': true} : {'ids': ids},
      );
      final map = _asMap(res);
      return MarkReadResult(
        updated: map['updated'] is num ? (map['updated'] as num).toInt() : 0,
        missing: _stringList(map['missing']),
      );
    } on HttpError catch (e) {
      if (e.statusCode == 404) {
        // 见上：全部失效不是错误，交给下一轮重试。
        return MarkReadResult(updated: 0, missing: List<String>.from(ids));
      }
      rethrow;
    }
  }

  Future<Object?> _get(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get<dynamic>(path, queryParameters: query);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _post(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.post<dynamic>(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Object? _unwrap(Response<dynamic> res) {
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw HttpError(status, 'HTTP $status', body: _bodyPreview(res.data));
    }
    return res.data;
  }

  SpbError _toSpbError(DioException e) {
    final inner = e.error;
    if (inner is SpbError) return inner;
    return mapDioError(e);
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return const {};
  }

  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is String) e,
    ];
  }

  static String? _bodyPreview(Object? data) {
    if (data == null) return null;
    final s = data is String ? data : data.toString();
    return s.length > 500 ? '${s.substring(0, 500)}…' : s;
  }
}

/// `GET /me/notices` 的响应。
class NoticeListResult {
  const NoticeListResult({required this.notices, required this.unread});

  final List<Notice> notices;

  /// 服务端给的未读数（查询失败时会降级为 0，故仅供参考）。
  final int unread;

  bool get isEmpty => notices.isEmpty;
}

/// `POST /me/notices/read` 的结果。
class MarkReadResult {
  const MarkReadResult({required this.updated, this.missing = const []});

  final int updated;

  /// 未命中的 id（不存在 / 不属于该用户 / 已失效）。**不是错误**。
  final List<String> missing;

  bool get isAllMissing => updated == 0 && missing.isNotEmpty;
}

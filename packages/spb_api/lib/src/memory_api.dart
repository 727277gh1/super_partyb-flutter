import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// 用户记忆（memory）领域 API 客户端。
///
/// 端点全部来自 Go API 真实路由 `internal/server/misc.go` 的
/// `registerMemRoutes`（挂载见 `ext_routes.go:37`，前缀 `/api/memories`）。
///
/// | 方法 | 路径 | 本类 |
/// |---|---|---|
/// | GET | `/api/memories?status=&category=&limit=&offset=` | [listMemories] |
/// | PATCH | `/api/memories/:memory_id` | [updateMemory] |
/// | DELETE | `/api/memories/:memory_id`（**软删 = 归档**） | [archiveMemory] |
/// | POST | `/api/memories` | **不实现**（见下） |
///
/// ## 为什么不实现 `POST /api/memories`
///
/// 内部面的 create 体是 `{category, content, topicKey, topicId}`，其中 `topicId`
/// 是服务端解析 `topic_key` 后写入的**内部标识**（外键）。客户端没有合法值
/// 来源，硬造一个会违反外键；外部面（`/open/memories`）专门为这一点改成
/// `topic_key` + 服务端 upsert，但它要 API Key（客户端不持有，见 AGENTS §5.1）。
/// 故第一版只做「浏览 / 编辑 / 归档 / 恢复」——记忆本来由提取器写入，用户的主要
/// 诉求是「看它在记什么、删掉记错的」。
///
/// ## 鉴权（与 §6.9 的旧记载不同）
///
/// `/api/memories` 上挂的 `requireScope("memories", …)` **只约束 API Key 分支**
/// （`api_key_auth.go:133` 的 `if !isAPIKeyAuth(c) { c.Next() }`）。客户端走网关注入
/// 的 `X-User-ID`，属登录态 → 不受 scope 限制，`GET`/`PATCH`/`DELETE` 均可用。
class MemoryApi {
  MemoryApi(this._dio);

  final Dio _dio;

  /// `GET /api/memories?status=&category=&limit=&offset=`
  ///
  /// 服务端 `parseLimit(c.Query("limit"), 200, 1000)`：默认 200、上限 1000。
  ///
  /// ## 分页（2026-11 起）
  ///
  /// `status` / `category` 过滤已**下推到 SQL**（过滤与分页在同一窗口内生效，
  /// `ORDER BY created_at DESC, id DESC` 补了稳定 tiebreak），故 `offset += limit`
  /// 不再漏项、`items.length == limit` 可当「还有下一页」（见 issue #121）。
  /// 该修复之前，带过滤条件时长度可能小于 `limit`，**不能**据此判断是否还有下一页。
  Future<List<UserMemory>> listMemories({
    UserMemoryStatus? status,
    UserMemoryCategory? category,
    int limit = 200,
    int offset = 0,
  }) async {
    final res = await _get(
      '/api/memories',
      query: {
        if (status != null && status != UserMemoryStatus.unknown)
          'status': status.wire,
        if (category != null && category != UserMemoryCategory.unknown)
          'category': category.wire,
        'limit': limit,
        'offset': offset,
      },
    );
    return unwrapItems(res, UserMemory.fromJson);
  }

  /// `PATCH /api/memories/:memory_id`
  ///
  /// 服务端是「未传字段保留原值」的补丁语义，但**用空串判断未传**
  /// （`misc.go` 的 `if body.Content != ""`）。因此：
  /// - 想把内容改成空串是不可能的（等价于不动），UI 要自己禁止空内容提交；
  /// - [status] 传 [UserMemoryStatus.active] 即「恢复归档」。
  ///
  /// 返回更新后的整条对象（服务端 `GetUserMemory` 重读后下发）。
  Future<UserMemory> updateMemory(
    String memoryId, {
    String? content,
    UserMemoryCategory? category,
    UserMemoryStatus? status,
  }) async {
    final body = <String, dynamic>{
      if (content != null) 'content': content,
      if (category != null && category != UserMemoryCategory.unknown)
        'category': category.wire,
      if (status != null && status != UserMemoryStatus.unknown)
        'status': status.wire,
    };
    if (body.isEmpty) {
      // 服务端会 200 返回原对象；空补丁是调用方的编程错误（多一次无意义往返）。
      throw ArgumentError('updateMemory 至少需要一个字段');
    }
    final res = await _patch('/api/memories/$memoryId', body: body);
    return UserMemory.fromJson(_asMap(res));
  }

  /// `DELETE /api/memories/:memory_id` —— **归档**（软删），不是物理删除。
  ///
  /// 响应是 `{id, status:"archived"}`；归档后提取器不再据此学习，
  /// 可用 [updateMemory] 传 `status: UserMemoryStatus.active` 恢复。
  Future<void> archiveMemory(String memoryId) async {
    await _delete('/api/memories/$memoryId');
  }

  // ==================== 传输层 ====================

  Future<Object?> _get(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get<dynamic>(path, queryParameters: query);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _patch(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.patch<dynamic>(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _delete(String path) async {
    try {
      final res = await _dio.delete<dynamic>(path);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// 取响应体并**显式检查状态码**。
  ///
  /// `createDio` 的 `validateStatus` 放行 4xx（见 `http_client.dart`），
  /// 故 404/403 不会抛 `DioException`。不在这里补判，[archiveMemory] 这类
  /// `Future<void>` 方法会把「删别人的记忆得到的 404」当成功——UI 把条目
  /// 从列表移走，而服务端从未归档。
  Object? _unwrap(Response<dynamic> res) {
    final code = res.statusCode ?? 0;
    if (code >= 400) {
      final body = res.data;
      throw HttpError(
        code,
        _errorMessage(body) ?? 'HTTP $code',
        body: body is String ? body : null,
      );
    }
    return res.data;
  }

  String? _errorMessage(Object? data) {
    if (data is Map) {
      final err = data['error'];
      if (err is String && err.isNotEmpty) return err;
    }
    if (data == null) return null;
    final s = data is String ? data : data.toString();
    return s.length > 500 ? '${s.substring(0, 500)}…' : s;
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
}

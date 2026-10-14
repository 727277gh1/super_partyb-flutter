import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// UFS（unified-file-service）API 客户端。
///
/// ## 为什么单独一个类而不是塞进 ChatApi
///
/// UFS 是**独立服务**（chi + SQLite，端口 8080），有自己的 baseUrl（网关前缀
/// `/ufs`）与错误体形状。混进 `ChatApi` 会让「一个类里有两套 baseUrl」
/// 这种问题在后面很难发现。
///
/// ## 路径前缀
///
/// 真实路由（`internal/handler/files.go` 与 `pkg/client/client.go` 一致）：
/// - `GET  /api/files`                       列表（[listFiles]）
/// - `GET  /api/files/{file_id}`             详情
/// - `GET  /api/files/{file_id}/download`    下载（[download]）
///
/// `baseUrl` 只到服务根（网关下为 `.../ufs`），`/api/files` 由本类拼接。
class UfsApi {
  UfsApi(this._dio);

  final Dio _dio;

  /// `GET /api/files`
  ///
  /// ## 参数与 query 键（对齐 `internal/handler/files.go` 的 `List`）
  ///
  /// | 参数 | query 键 | 说明 |
  /// |---|---|---|
  /// | [pathPrefix] | `path_prefix` | 只列该前缀下的条目（如 `grp_1/`） |
  /// | [updatedSince] | `updated_since` | 增量游标，服务端返回 `updated_at >= 该值` |
  /// | [includeDeleted] | `include_deleted` | 增量同步**必须**为 true，否则感知不到删除 |
  /// | [excludePrefix] | `exclude_prefix` | **可重复**：排除机器生成的附属产物 |
  /// | [page] / [pageSize] | `page` / `page_size` | 服务端 page_size 上限 100 |
  /// | [ownerType] | `owner_type` | 默认 `user`；配合服务端自动填 owner_id |
  ///
  /// ## `updated_since` 是「含等号」的比较（重要）
  ///
  /// 服务端是 `updated_at >= 游标`，因此**游标那一秒的文件每轮都会重复出现**。
  /// 这是有意设计（保证不漏），客户端靠 etag 比对跳过已同步的——所以
  /// [includeDeleted] 与 etag 比对必须成对使用，只做其一都会出问题：
  /// 只带 include_deleted 会反复重下，只比 etag 会漏掉远端删除。
  ///
  /// ## `owner_id` 为什么不传
  ///
  /// 服务端在 `owner_type=user` 且未给 `owner_id` 时自动填当前用户
  /// （`files.go` 的 `resolveOwnerParams` 分支），隔离由服务端强制。
  /// 客户端传 owner_id 既无必要，也多了一个越权面。
  Future<UfsFilePage> listFiles({
    String? pathPrefix,
    String? updatedSince,
    bool includeDeleted = false,
    List<String> excludePrefix = const [],
    int page = 1,
    int pageSize = 20,
    String ownerType = 'user',
  }) async {
    final res = await _get(
      '/api/files',
      query: {
        'owner_type': ownerType,
        if (pathPrefix != null && pathPrefix.isNotEmpty)
          'path_prefix': pathPrefix,
        if (updatedSince != null && updatedSince.isNotEmpty)
          'updated_since': updatedSince,
        // 只在 true 时发送：服务端只认 "true"/"1"，发 "false" 虽等价于不发，
        // 但会让抓包/日志里出现一个看起来像「已开启」的参数。
        if (includeDeleted) 'include_deleted': 'true',
        if (excludePrefix.isNotEmpty) 'exclude_prefix': excludePrefix,
        'page': page,
        'page_size': pageSize,
      },
    );
    return UfsFilePage.fromJson(_asMap(res));
  }

  /// `GET /api/files/{file_id}` —— 单个条目的元数据。
  Future<UfsFileEntry> getFile(String fileId) async {
    final res = await _get('/api/files/$fileId');
    return UfsFileEntry.fromJson(_asMap(res));
  }

  /// `GET /api/files/{file_id}/download`
  ///
  /// ## 用 [ifNoneMatch] 做条件下载
  ///
  /// 传上一轮记录的 etag，服务端命中时返回 **304** 且不带正文
  /// （`files.go` 的 `If-None-Match` 分支）。这能省掉绝大部分重复传输。
  ///
  /// ## 返回值语义
  ///
  /// 返回 [UfsDownload]：
  /// - [UfsDownload.notModified] 为 true → 内容未变，**不是错误**，调用方应跳过；
  /// - 否则 [UfsDownload.bytes] 是新内容。
  ///
  /// ## 为什么 304 不能用「抛异常」表达
  ///
  /// 304 是**正常业务结果**（缓存命中），把它做成异常会迫使调用方在
  /// `catch` 里分辨「304 不是错误」，而 `catch` 块天然适合处理异常情况。
  /// 更糟的是：`createDio` 的 `validateStatus` 放行所有 <500，304 会带着
  /// 空响应体正常返回——若这里不显式判状态码，会被当成「下载到了 0 字节文件」，
  /// 然后**把本地已有文件覆盖成空文件**。
  ///
  /// 返回体用 `ResponseType.bytes`：文件内容必须是原始字节，用默认的
  /// `ResponseType.json` 会尝试按 JSON 解析（二进制文件直接失败，文本文件被
  /// 当作 JSON 解析后再序列化，内容被破坏）。
  Future<UfsDownload> download(String fileId, {String? ifNoneMatch}) async {
    try {
      final res = await _dio.get<List<int>>(
        '/api/files/$fileId/download',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            if (ifNoneMatch != null && ifNoneMatch.isNotEmpty)
              'If-None-Match': ifNoneMatch,
          },
        ),
      );

      final status = res.statusCode ?? 0;

      // 304：内容未变（不是错误）。放在最前面判，避免被下面的 2xx 判定漏掉。
      if (status == 304) {
        return UfsDownload(
          notModified: true,
          etag: _etagOf(res.headers) ?? ifNoneMatch,
        );
      }

      if (status < 200 || status >= 300) {
        throw HttpError(status, 'HTTP $status', body: _bodyPreview(res.data));
      }

      final data = res.data ?? const <int>[];
      return UfsDownload(
        notModified: false,
        bytes: data,
        etag: _etagOf(res.headers),
        contentType: res.headers.value('content-type'),
      );
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// `GET /api/files/{file_id}/thumbnails/{size}`
  ///
  /// 服务端在缺失或内容已变更时**同步补生成**（`internal/service/thumbnail.go`），
  /// 响应带 `Cache-Control: private, max-age=3600` 与 `ETag`。
  ///
  /// ## 合法 size 只有四档
  ///
  /// `thumbnailSizes = []int{64, 128, 256, 512}`（`thumbnail.go`）。传其它值
  /// 服务端返回 **400 缩略图尺寸无效**——这里不做客户端白名单校验：服务端才是
  /// 权威，而 400 会被下面的非 2xx 分支翻译成带状态码的 [HttpError]，比本地
  /// 抛一个语义模糊的 `ArgumentError` 更好定位。
  ///
  /// ## 返回 null 的两种情形（都不是错误）
  ///
  /// - **501 缩略图服务未启用**：部署未开该能力时的正常响应。绝不能抛错，
  ///   否则一张图就能让整卡显示失败（用户还以为文件坏了），且可能被上层
  ///   误当成「下载失败」而阻断下载。
  /// - **304**：内容未变。本方法**不发送** `If-None-Match`（缩略图是短时缓存
  ///   的展示件，不值得为它维护条件请求状态），故正常不会出现；但 `createDio`
  ///   的 `validateStatus` 放行所有 <500，304 会带空正文正常返回——不显式判
  ///   就会变成「取到一个 0 字节图片」，`Image.memory` 抛异常。
  ///
  /// 调用方拿到 null 或空字节时**退化为图标**（`AgentFileCard._leading`）。
  ///
  /// ## 为什么用 `ResponseType.bytes`
  ///
  /// 同 [download]：默认的 `ResponseType.json` 会拿 PNG 去按 JSON 解析，
  /// 直接失败或把内容破坏掉。
  Future<List<int>?> thumbnail(String fileId, {int size = 256}) async {
    try {
      final res = await _dio.get<List<int>>(
        '/api/files/$fileId/thumbnails/$size',
        options: Options(responseType: ResponseType.bytes),
      );

      final status = res.statusCode ?? 0;

      // 304：无正文可渲染（见上）。放在 2xx 判定之前，否则会被下面的
      // 非 2xx 分支当成错误抛出去。
      if (status == 304) return null;

      if (status < 200 || status >= 300) {
        throw HttpError(status, 'HTTP $status', body: _bodyPreview(res.data));
      }

      return res.data;
    } on DioException catch (e) {
      // 501 **不**走上面的分支：`validateStatus` 只放行 <500，故 501 由 dio
      // 抛成 DioException，在错误拦截器里被映射成 HttpError(501)。要在此处
      // 把它捞回来，而不是让它冒泡到卡片。
      final err = _toSpbError(e);
      if (err is HttpError && err.statusCode == 501) return null;
      throw err;
    }
  }

  /// 从响应头取 ETag。
  ///
  /// 服务端可能返回强 etag（`"abc"`）或弱 etag（`W/"abc"`）；**原样保留**，
  /// 不要剥掉引号或 `W/` 前缀——服务端的 `etagMatch` 会同时处理两种形式，
  /// 客户端改写反而会让下一轮的 `If-None-Match` 匹配不上。
  static String? _etagOf(Headers headers) {
    final v = headers.value('etag');
    return (v == null || v.isEmpty) ? null : v;
  }

  // ==================== 内部 HTTP 辅助 ====================
  //
  // 与 `ChatApi` 相同的约定：`createDio` 的 `validateStatus: s < 500`（排除
  // 401/403）意味着 **4xx 不会抛 DioException**。不在此显式判状态码，
  // `404 {"error":"..."}` 会被当成成功响应，`fromJson` 再把它解析成
  // 「字段全空的对象」——不报错、不抛异常，UI 表现为「数据莫名是空的」。
  // 故此处补齐 4xx 分支，与 `ChatApi._unwrap` 保持一致。

  Object? _unwrap(Response<dynamic> res) {
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw HttpError(status, 'HTTP $status', body: _bodyPreview(res.data));
    }
    return res.data;
  }

  static String? _bodyPreview(Object? data) {
    if (data == null) return null;
    final s = data is String ? data : data.toString();
    return s.length > 500 ? '${s.substring(0, 500)}…' : s;
  }

  Future<Object?> _get(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get<dynamic>(path, queryParameters: query);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
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

/// 下载结果（[UfsApi.download] 的返回）。
///
/// 用「一个结果对象 + [notModified] 标志」而不是「返回 `Uint8List?`」：
/// null 无法区分「304 未变更」与「服务端返回了空文件」，而这两者的处理
/// 完全相反（跳过 vs 覆盖本地为空）。
class UfsDownload {
  const UfsDownload({
    required this.notModified,
    this.bytes,
    this.etag,
    this.contentType,
  });

  /// true = 服务端返回 304，内容未变，**不应写入本地**。
  final bool notModified;

  /// 文件内容。仅当 [notModified] 为 false 时有效。
  final List<int>? bytes;

  /// 响应头里的 ETag（304 时也返回，便于更新本地记录）。
  final String? etag;

  final String? contentType;

  /// 内容长度（未变更时为 0）。
  int get length => bytes?.length ?? 0;

  @override
  String toString() => notModified
      ? 'UfsDownload(304 未变更, etag=$etag)'
      : 'UfsDownload($length 字节, etag=$etag)';
}

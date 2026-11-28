import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// 小程序工作台 BFF API 客户端（`/chat/miniapp/*`）。
///
/// ## 为什么单独一个类而不是塞进 `ChatApi`
///
/// 这组端点是**为小程序专门做的投影层**：它把 `chat_groups` + turns + events +
/// confirmations 投影成「工作（work）」，并带小程序专属能力（产物、通知订阅额度、
/// 上传）。与 `ChatApi` 面向的「对话」语义不同，字段命名风格也不同
/// （`work_id` vs `group_id`、`status_label` 服务端下发）。
///
/// ## 与 `ChatApi` 的三处命名/形状差异（都会静默出错）
///
/// 1. **`work_id` 就是 group id**。服务端没有 works 表。
/// 2. **`listWorks` 的 `cursor` 是 offset**（`parseOffset`），不是不透明游标。
/// 3. **`workEvents` 返回数据库原始行**（`payloadJson` 字符串、
///    `agentId` 为 `{String,Valid}`），**不能**用 `ChatEvent.fromJson` 解析。
///    故它返回 [MiniappWorkEvent] 而非 [ChatEvent]。
///
/// ## 不含长连接推送端点
///
/// 服务端另有 `/ws-tickets` 与 `/ws`，本仓库**禁止引入长连接推送**
/// （AGENTS.md §6.1：会造成两套事件推送链路，且 broker 是按 userId 的单订阅模型）。
/// 实时更新复用既有 SSE `/users/:uid/chat/stream`，故本类**不封装**那两个端点。
///
/// ## 每个方法都显式判 4xx
///
/// `createDio` 的 `validateStatus` 放行所有 <500（401/403 除外），故 **4xx 不会抛
/// `DioException`**。不在此判状态码，`404 {"error":"工作不存在"}` 会被当成成功响应，
/// `fromJson` 再把它解析成「字段全空的对象」——不报错、不抛异常，UI 表现为
/// 「数据莫名是空的」。与 `ChatApi`/`UfsApi` 同一约定。
class MiniappApi {
  MiniappApi(this._dio);

  final Dio _dio;

  // ==================== 工作 ====================

  /// `GET /chat/miniapp/works?status=&limit=&cursor=`
  ///
  /// ## `status` 的三态
  ///
  /// 服务端 `c.DefaultQuery("status", "active")`，且只在 `status == "all"` 时
  /// 不过滤 group 状态。传别的值（如 `archived`）会走 `groupStatus = "active"`
  /// ——即**静默退回只列活跃**，不报错。故调用方只用 `active` / `all`。
  ///
  /// ## `cursor` 是 offset
  ///
  /// 见 [MiniappWorkPage.nextCursor] 的说明。这里用 `int?` 而非 `String?` 表达，
  /// 从签名上就挡住「传 id 游标」。
  Future<MiniappWorkPage> listWorks({
    String status = 'active',
    int limit = 20,
    int? cursor,
  }) async {
    final res = await _get(
      '/chat/miniapp/works',
      query: {
        'status': status,
        'limit': limit,
        if (cursor != null) 'cursor': cursor,
      },
    );
    return MiniappWorkPage.fromJson(_asMap(res));
  }

  /// `POST /chat/miniapp/works`
  ///
  /// 建工作（= 建 group）+ 可选地发首条消息。服务端返回 `{work, dispatch}`。
  ///
  /// [goal] 可选：服务端留空（NULL）而非写占位符——此前固定传 `'新会话'` 会让
  /// 会话设置面板把占位符当已配置目标回显。
  ///
  /// ⚠️ [dispatch] 里的失败是**嵌在 200 响应体**里的（`{error}`），不是错误码。
  /// 调用方需检查 `dispatch.hasError`。
  Future<MiniappWorkCreateResult> createWork({
    String? goal,
    String input = '',
    String? templateId,
    List<String> fileIds = const [],
  }) async {
    final res = await _post(
      '/chat/miniapp/works',
      body: {
        if (goal != null && goal.isNotEmpty) 'goal': goal,
        if (input.isNotEmpty) 'input': input,
        if (templateId != null && templateId.isNotEmpty)
          'template_id': templateId,
        if (fileIds.isNotEmpty) 'file_ids': fileIds,
      },
    );
    final map = _asMap(res);
    return MiniappWorkCreateResult(
      work: MiniappWorkDetail.fromJson(_asMap(map['work'])),
      dispatch: map['dispatch'] is Map
          ? MiniappDispatchResult.fromJson(_asMap(map['dispatch']))
          : null,
      raw: map,
    );
  }

  /// `GET /chat/miniapp/works/:work_id`
  ///
  /// 返回 `{work: {...}}`。不存在 → 404「工作不存在」（[HttpError.isNotFound]）。
  Future<MiniappWorkDetail> getWork(String workId) async {
    final res = await _get('/chat/miniapp/works/$workId');
    return MiniappWorkDetail.fromJson(_asMap(_asMap(res)['work']));
  }

  /// `POST /chat/miniapp/works/:work_id/messages`
  ///
  /// 发消息（建 turn）。成功 **201**，返回 `{work_id, dispatch}`。
  ///
  /// `input` 服务端 `binding:"required"`：空串会得到 400。仅传 [fileIds] 而
  /// 不带文本的场景，服务端允许（`binding` 只要求字段存在，空串会失败）——
  /// 故调用方要么给非空 [input]，要么改走 [uploadFile]。
  Future<MiniappDispatchResult> sendMessage(
    String workId, {
    required String input,
    List<String> fileIds = const [],
  }) async {
    final res = await _post(
      '/chat/miniapp/works/$workId/messages',
      body: {'input': input, if (fileIds.isNotEmpty) 'file_ids': fileIds},
    );
    final map = _asMap(res);
    return MiniappDispatchResult.fromJson({
      ..._asMap(map['dispatch']),
      // work_id 在顶层，dispatch 里没有；合并进去让结果自带归属。
      'group_id': map['work_id'],
    });
  }

  /// `POST /chat/miniapp/works/:work_id/complete`
  ///
  /// 完成工作：**真归档 group** + 标 `metadata.miniapp.status=completed` +
  /// 任务表全部 completed。返回 `{work, interruption}`。
  ///
  /// 幂等性：group 已非 `active` 时服务端返回 **404**「工作不存在」（不是 200），
  /// 故重复点「完成」会得到 404——调用方应把它当「已经是完成态」处理。
  Future<MiniappWorkDetail> completeWork(String workId) async {
    final res = await _post('/chat/miniapp/works/$workId/complete');
    return MiniappWorkDetail.fromJson(_asMap(_asMap(res)['work']));
  }

  /// `POST /chat/miniapp/works/:work_id/stop`
  ///
  /// 停止工作：取消 queued/running turn + 中断 executor + 归档 group。
  /// 返回 `{work, interruption}`（`interruption.turn_ids` 为被取消的 turn）。
  ///
  /// 与 [completeWork] 同：group 非 active 时 404。
  Future<MiniappWorkDetail> stopWork(String workId) async {
    final res = await _post('/chat/miniapp/works/$workId/stop');
    return MiniappWorkDetail.fromJson(_asMap(_asMap(res)['work']));
  }

  // ==================== 事件 ====================

  /// `GET /chat/miniapp/works/:work_id/events?limit=`
  ///
  /// ## 返回数据库原始行，**不是** SSE 事件
  ///
  /// 服务端把 `[]queries.ChatEvent` 直接交给 `c.JSON`，于是形状与 SSE/timeline
  /// 不同：事件 id 是 `id`（非 `eventId`）、负载是 `payloadJson` **字符串**
  /// （非 `payload` 对象）、`agentId` 是 `{String,Valid}`。用 `ChatEvent.fromJson`
  /// 会抛 `FormatException`（它要求 `eventId`）。详见 [MiniappWorkEvent]。
  ///
  /// `limit` 服务端 `parseLimit(q, 100, 500)`：默认 100、上限 500。
  ///
  /// ⚠️ 服务端**不校验 work 归属**（`workEvents` 只查 `group_id`），且不返回
  /// 游标——每次都是最新 N 条。增量刷新请用 SSE，本端点用于首次加载。
  Future<List<MiniappWorkEvent>> workEvents(
    String workId, {
    int limit = 100,
  }) async {
    final res = await _get(
      '/chat/miniapp/works/$workId/events',
      query: {'limit': limit},
    );
    return _unwrapList(res, MiniappWorkEvent.fromJson);
  }

  // ==================== 产物 ====================

  /// `GET /chat/miniapp/works/:work_id/artifacts`
  ///
  /// 返回 `{items: [...]}`。产物来自 `agent.file.*` 事件的投影
  /// （倒序去重、跳过 `reports/tts/**`），**不含** `content`。
  Future<List<MiniappArtifact>> listArtifacts(String workId) async {
    final res = await _get('/chat/miniapp/works/$workId/artifacts');
    return _unwrapList(res, MiniappArtifact.fromJson);
  }

  /// `GET /chat/miniapp/works/:work_id/artifacts/:artifact_id`
  ///
  /// 单个产物详情，返回 `{artifact: {...}}`。文本类且不超阈值时**内联**
  /// `content`（见 [MiniappArtifact.content]）。
  ///
  /// 归属校验：`ufsFileBelongsToWork` 失败时返回 **404**（不是 403）——服务端
  /// 刻意不区分「不存在」与「不属于本 work」，避免存在性探针。
  Future<MiniappArtifact> getArtifact(String workId, String artifactId) async {
    final res = await _get('/chat/miniapp/works/$workId/artifacts/$artifactId');
    return MiniappArtifact.fromJson(_asMap(_asMap(res)['artifact']));
  }

  /// `GET /chat/miniapp/works/:work_id/artifacts/:artifact_id/download`
  ///
  /// 下载产物原始字节。
  ///
  /// ## 为什么必须用 `ResponseType.bytes`
  ///
  /// 服务端 `c.Data(200, contentType, content)` 返回**原始字节**并带
  /// `Content-Disposition`。用默认的 `ResponseType.json` 会尝试按 JSON 解析
  /// （二进制直接失败；文本文件被解析后再序列化，内容被破坏）。
  ///
  /// ## 无 304 分支（与 UFS 下载不同）
  ///
  /// 本端点不处理 `If-None-Match`，故没有「未变更」语义——每次都传完整字节。
  /// 返回值就是字节列表，不需要 `UfsDownload` 那种结果对象。
  Future<List<int>> downloadArtifact(String workId, String artifactId) async {
    try {
      final res = await _dio.get<List<int>>(
        '/chat/miniapp/works/$workId/artifacts/$artifactId/download',
        options: Options(responseType: ResponseType.bytes),
      );
      final status = res.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw HttpError(status, 'HTTP $status', body: _bodyPreview(res.data));
      }
      return res.data ?? const <int>[];
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// `POST /chat/miniapp/works/:work_id/files`（multipart，字段名 `file`）
  ///
  /// 上传文件到 work 的 workspace（转存 UFS），返回 `{work_id, artifact, upload}`。
  ///
  /// ## 字段名必须叫 `file`
  ///
  /// 服务端 `c.FormFile("file")`，名字不对会得到 400「缺少 file」。
  ///
  /// ## 大小上限是服务端配置
  ///
  /// 超过 `WorkbenchFileContextMaxBytes` 时返回 **413**。客户端**不应**自己
  /// 复刻这个上限（服务端可配，会漂移）——把 413 翻成用户可读提示即可。
  ///
  /// [relativePath] 会做路径归一化与黑名单校验，非法时服务端 400。
  Future<MiniappArtifact> uploadFile(
    String workId, {
    required List<int> bytes,
    required String filename,
    String? relativePath,
  }) async {
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: filename),
        if (relativePath != null && relativePath.isNotEmpty)
          'relative_path': relativePath,
      });
      final res = await _dio.post<dynamic>(
        '/chat/miniapp/works/$workId/files',
        data: form,
      );
      _unwrap(res);
      return MiniappArtifact.fromJson(_asMap(_asMap(res.data)['artifact']));
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  // ==================== 确认卡 ====================

  /// `GET /chat/miniapp/confirmations?group_id=&limit=&offset=`
  ///
  /// 跨 work 的待确认列表。返回 `{items, pending_count}`。
  ///
  /// ## 传 `group_id` 与不传的差别
  ///
  /// 不传走 `ListChatConfirmationsForUser`（跨全部 work）；传了走
  /// `ListChatConfirmationsForGroup`（单个 work，**不受其它 work 的分页占用**）。
  /// 详情页应传 `group_id`——否则一个有很多待办的 work 会把别的 work 的卡挤出
  /// 分页窗口。
  ///
  /// 注意服务端返回的 `items` **只有 pending**（查询按 status 过滤），且
  /// `pending_count == items.length`（不是全量计数）。
  Future<List<MiniappConfirmation>> listConfirmations({
    String? workId,
    int limit = 20,
    int offset = 0,
  }) async {
    final res = await _get(
      '/chat/miniapp/confirmations',
      query: {
        if (workId != null && workId.isNotEmpty) 'group_id': workId,
        'limit': limit,
        'offset': offset,
      },
    );
    return _unwrapList(res, MiniappConfirmation.fromJson);
  }

  /// `POST /chat/miniapp/confirmations/:confirmation_id/resolve`
  ///
  /// 请求体 `{action, comment}`。
  ///
  /// ## 路径**不带** group_id（与 webapp 的 `/api/chat/groups/:gid/...` 不同）
  ///
  /// 这是两套独立端点，别把 `ChatApi.resolveConfirmation` 的路径抄过来。
  /// 服务端按 `confirmation_id` + `user_id` 定位（`UpdateChatConfirmationMine`）。
  ///
  /// ## `action` 默认值是 `"resolved"`，不是错误
  ///
  /// 服务端 `firstNonEmpty(body.Action, "resolved")`。`resolved` 会被写进
  /// `resolved_action` 而 `status` 固定为 `resolved`（曾因把 action 直接写
  /// status 违反 CHECK 约束导致 500，确认全积压）。故空 action 不报错，只是
  /// 丢掉了用户的选择——调用方应传 [MiniappConfirmationOption.key]。
  ///
  /// ## 404 的两种含义
  ///
  /// `affected == 0` 时返回 **404**「confirmation 不存在或已处理」：可能是
  /// 非本人、已处理、或已过期。服务端刻意统一成一个响应，避免存在性探针。
  /// 调用方应把 404 当「这张卡不用再显示了」处理，而不是错误。
  Future<void> resolveConfirmation(
    String confirmationId, {
    String action = 'approve',
    String? comment,
  }) => _post(
    '/chat/miniapp/confirmations/$confirmationId/resolve',
    body: {'action': action, if (comment != null) 'comment': comment},
  );

  // ==================== 通知订阅 ====================

  /// `GET /chat/miniapp/notifications/subscriptions`
  ///
  /// 返回 `{items: [...]}`，每项含 `template_key` / `remaining_quota` / `enabled`。
  ///
  /// 数据库不可用时服务端返回 **503**（不是 500），故调用方应把 503 当
  /// 「暂时不可用」而非「永久失败」。
  Future<List<MiniappNotificationSubscription>>
  listNotificationSubscriptions() async {
    final res = await _get('/chat/miniapp/notifications/subscriptions');
    return _unwrapList(res, MiniappNotificationSubscription.fromJson);
  }

  /// `POST /chat/miniapp/notifications/subscriptions`
  ///
  /// 请求体 `{"accepted": {"<template_key>": n}}`。
  ///
  /// ## 额度语义（n 的方向很关键）
  ///
  /// - `n > 0`：微信弹窗 accept，**累加**额度（`AddQuota`）；
  /// - `n == 0`：用户拒收，额度**归零并禁用**（`ResetQuota`），再次 accept 恢复。
  ///
  /// ## 未知 key 是 400（不会静默忽略）
  ///
  /// 服务端逐个 `KnownTemplate` 校验，有一个不认就整体 400。故**不要**传
  /// 客户端自造 key——传了会让整批保存失败。
  ///
  /// 返回保存后的完整列表（`{items}`）。
  Future<List<MiniappNotificationSubscription>> saveNotificationSubscriptions(
    Map<String, int> accepted,
  ) async {
    final res = await _post(
      '/chat/miniapp/notifications/subscriptions',
      body: {'accepted': accepted},
    );
    return _unwrapList(res, MiniappNotificationSubscription.fromJson);
  }

  // ==================== 内部 HTTP 辅助 ====================

  Object? _unwrap(Response<dynamic> res) {
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw HttpError(status, 'HTTP $status', body: _bodyPreview(res.data));
    }
    return res.data;
  }

  /// 从 `{items: [...]}` 或裸数组里取出列表。
  ///
  /// 显式判 4xx（见类文档）：否则错误体会被解析成空列表，UI 显示「暂无数据」，
  /// 而实际是请求失败。
  List<T> _unwrapList<T>(
    Object? res,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final map = _asMap(res);
    final raw = map['items'];
    if (raw is! List) return const [];
    final out = <T>[];
    for (final e in raw) {
      if (e is Map) out.add(fromJson(Map<String, dynamic>.from(e)));
    }
    return out;
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

  Future<Object?> _post(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.post<dynamic>(path, data: body);
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

/// `POST /chat/miniapp/works` 的响应（`{work, dispatch}`）。
///
/// `dispatch` 为 null 表示建工作时**没带 input / file_ids**（服务端
/// `if input != "" || len(fileIds) > 0` 才派发），即「只建了个空工作」。
class MiniappWorkCreateResult {
  const MiniappWorkCreateResult({
    required this.work,
    this.dispatch,
    this.raw = const {},
  });

  final MiniappWorkDetail work;

  /// 首条消息的派发结果。null = 未派发（无 input 且无 file_ids）。
  final MiniappDispatchResult? dispatch;

  final Map<String, dynamic> raw;

  /// 工作 id（= group id）。
  String get workId => work.id;

  @override
  String toString() => 'MiniappWorkCreateResult($workId, dispatch=$dispatch)';
}

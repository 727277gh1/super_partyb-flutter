/// 回传链路（[DeliverableUploadUseCase]）的真实装配适配器。
///
/// ## 为什么放 domain 而不是各 app 写一份
///
/// 与下行同步侧的 `UfsFileDownloader`（同一文件隔壁）同一理由：这是纯粹的
/// **类型适配**
/// （`ChatApi` / `UfsApi` → 窄接口），没有任何平台或环境依赖。放在 domain 里
/// 让两个 app 共用，避免各写一份——那两份很容易在「分页终止条件」「304 怎么
/// 表达」这类细节上产生分歧（这些细节恰恰是最难测试的边界）。
///
/// app 层（`providers.dart`）只做**接线**：构造适配器、填入当前用户 id，
/// 不写逻辑。
library;

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'deliverable_upload_usecase.dart';

/// 把 [ChatApi] 适配成 [UploadSender]。
///
/// 实现体是一次**逐字转发**（参数与 `ChatApi.uploadWorkspaceFile` 完全对齐），
/// 不加任何包装语义——接口是适配层不是抽象层，多一层「语义化包装」只会让
/// 「接口上说的」与「实际发的请求」产生漂移空间。
class ChatApiUploadSender implements UploadSender {
  const ChatApiUploadSender(this.api);

  final ChatApi api;

  @override
  Future<WorkspaceFileUpload> uploadWorkspaceFile({
    required String groupId,
    required String relativePath,
    List<int>? bytes,
    String? path,
    required String filename,
    String? contentType,
  }) => api.uploadWorkspaceFile(
    groupId: groupId,
    relativePath: relativePath,
    bytes: bytes,
    path: path,
    filename: filename,
    contentType: contentType,
  );
}

/// 把 [ChatApi] 适配成 [QuickCaptureSender]（413 兜底的附件链）。
class ChatApiQuickCaptureSender implements QuickCaptureSender {
  const ChatApiQuickCaptureSender(this.api);

  final ChatApi api;

  @override
  Future<QuickCaptureUpload> uploadQuickCaptureAttachment({
    List<int>? bytes,
    String? path,
    required String filename,
    String? contentType,
  }) => api.uploadQuickCaptureAttachment(
    bytes: bytes,
    path: path,
    filename: filename,
    contentType: contentType,
  );

  @override
  Future<void> enqueueQuickCapture({
    String input = '',
    List<String> attachments = const [],
  }) => api.enqueueQuickCapture(input: input, attachments: attachments);
}

/// 把 [ChatApi] 适配成 [UploadNotifier]。
///
/// [userId] 由装配层捕获（来自 `GET /api/auth/me`，经网关认证）——本类不做
/// 身份解析，那不是适配的职责。
class ChatApiUploadNotifier implements UploadNotifier {
  const ChatApiUploadNotifier(this.api, this.userId);

  final ChatApi api;

  /// 当前用户 id（`/users/:uid/chat/messages` 路径参数）。
  final String userId;

  @override
  Future<void> sendMessage({
    required String userId,
    required String input,
    String? groupId,
    String? requestId,
  }) => api.sendMessage(
    userId,
    input: input,
    groupId: groupId,
    requestId: requestId,
  );
}

/// 把 [UfsApi] 适配成 [RemoteWorkspace]。
///
/// ## [listAll] 的分页与下行同步共用同一套边界规则
///
/// 用 `total` 判断「还有没有下一页」（不是「本页条数 == pageSize」，总数恰为
/// 整数倍时会多发一次空请求）；以「本页为空」为硬终止（防御服务端 total 异常
/// 导致死循环）；超过 [maxPages] 视为契约破坏并中止。这些规则与
/// `DeliverableSyncUseCase._listAll` 相同——若两处实现不一致，就会出现
/// 「下行同步能拉全、回传预检拉不全」的诡异差异（预检把「清单里没有」判成
/// 「远端已删」），故刻意复制其结构并逐条对齐。
class UfsRemoteWorkspace implements RemoteWorkspace {
  const UfsRemoteWorkspace(
    this.ufs, {
    this.pageSize = 100,
    this.maxPages = 200,
  });

  final UfsApi ufs;

  /// 每页条数。服务端上限 100（`internal/handler/files.go`）。
  final int pageSize;

  final int maxPages;

  @override
  Future<List<UfsFileEntry>> listAll({
    required String pathPrefix,
    bool includeDeleted = true,
  }) async {
    final all = <UfsFileEntry>[];
    var page = 1;

    while (true) {
      final result = await ufs.listFiles(
        pathPrefix: pathPrefix,
        includeDeleted: includeDeleted,
        page: page,
        pageSize: pageSize,
      );
      all.addAll(result.items);

      if (result.items.isEmpty) break;
      if (!result.hasMore(page: page, pageSize: pageSize)) break;

      page++;
      if (page > maxPages) {
        throw ParseError('回传清单分页超过 $maxPages 页，已中止（疑似服务端 total 异常）');
      }
    }
    return all;
  }

  @override
  Future<List<int>> downloadBytes(String fileId) async {
    // 不带 `ifNoneMatch`：要的是 agent 版本的**当前**内容，条件请求没有意义
    // （预检已判定 etag 变了）。
    //
    // 故收到 304 属于**契约破坏**，必须抛错而不是返回空列表：空列表会被上层
    // 当成「agent 版本是 0 字节」而上传一个空的 `_conflict/` 副本——冲突记录
    // 就静默失真了（而抛错只会让这一个文件记为失败，用户可重跑）。
    final result = await ufs.download(fileId);
    if (result.notModified) {
      throw ParseError('无条件下载却收到 304（file_id=$fileId），无法取得远端内容');
    }
    return result.bytes ?? const <int>[];
  }
}

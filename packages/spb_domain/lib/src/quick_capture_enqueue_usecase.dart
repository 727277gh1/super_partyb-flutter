import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// 待发送的附件（已读入内存的字节 + 原始文件名）。
///
/// ## 为什么用「字节 + 文件名」而不是 `File` 路径
///
/// 本包是**纯 Dart 包**（禁止依赖 Flutter），而 `dart:io` 的 `File` 在 web
/// 构建下不可用。更重要的是：桌面端拖拽给到的可能是内存中的字节（剪贴板粘贴、
/// 拖入的虚拟文件），未必有可读的本地路径。故上层（`spb_platform`）负责把
/// 各种来源归一成字节，本层只处理归一后的形态。
///
/// ## 为什么没有「上传进度」字段
///
/// 进度是 UI 状态，不是领域状态。用例只回答「这批附件最终成功/失败了哪些」，
/// 进度上报由调用方通过 [QuickCaptureEnqueueUseCase.submit] 的可选回调自行维护。
class QuickCaptureAttachment {
  const QuickCaptureAttachment({
    this.bytes,
    this.path,
    required this.filename,
    this.contentType,
  }) : assert(
         (bytes == null) != (path == null),
         'QuickCaptureAttachment 必须且只能给 bytes 或 path 之一',
       );

  /// 文件内容（仅在**没有**本地路径时提供）。
  ///
  /// 用 `List<int>` 而不是 `Uint8List`：本包不依赖 `dart:typed_data` 之外的
  /// 任何东西，而 `List<int>` 是所有来源（`File.readAsBytes`、剪贴板、
  /// 拖拽 API）的公共超集，无需在边界处转换。
  final List<int>? bytes;

  /// 本地文件路径（有则优先，传输层从磁盘流式读取）。
  ///
  /// ## 为什么需要它（只有 bytes 不够）
  ///
  /// 桌面端附件的常见来源是拖拽/文件选择，两者都拿得到磁盘路径。若强制先
  /// `readAsBytes`，一个 50 MiB 的文件会在内存里存两份（调用方一份 +
  /// multipart 缓冲一份），而上传发生在**用户等待的同步路径**上。
  ///
  /// 剪贴板粘贴是唯一拿不到路径的来源（字节本就在内存里），那条路仍用
  /// [bytes]。
  final String? path;

  /// 原始文件名（服务端会安全化后使用）。
  final String filename;

  /// MIME 类型。为空时由服务端按扩展名/内容推断。
  final String? contentType;

  @override
  String toString() => 'QuickCaptureAttachment($filename)';
}

/// 提交结果。
///
/// ## 为什么是「一个对象 + 成功/失败两个列表」而不是 sealed 家族
///
/// 与 [QuickCaptureOutcome] 不同，这里的失败是**可部分**的：3 个附件里 1 个
/// 上传失败，消息仍然可以带着另外 2 个发出去。用 sealed 家族会强迫调用方在
/// 「全成功/全失败」之间二选一，而真实情况是「部分成功且已发出」。
///
/// 但**已投递**与**未投递**必须是互斥的整体状态：见 [delivered] 的说明。
class QuickCaptureEnqueueResult {
  const QuickCaptureEnqueueResult({
    required this.delivered,
    this.uploaded = const [],
    this.failedUploads = const [],
    this.error,
  });

  /// 消息是否已投进队列。
  ///
  /// ## 为什么这个字段是必须的
  ///
  /// 上传成功但投递失败时，附件已经落在服务端（UFS 的 /inbound/ 暂存区），而消息
  /// **没有**发出去。若调用方只看 [uploaded] 非空就认为「发出去了」，用户会以为
  /// 消息已发送而实际永远不会被处理——静默丢消息。
  ///
  /// ⚠️ 这种情况下的服务端残留**没有 TTL 保证**：附件直传 UFS 后（见
  /// commit `72f10aca`），不再经 mq-server 的引用回收，而 UFS 侧的清理是默认
  /// 关闭的粗粒度 TTL。详见 super_partyb issue #36。
  ///
  /// 反之若 [delivered] 为 true，即使 [failedUploads] 非空，消息也确实发出了
  /// （只是少带了几个附件），调用方应清空输入框并提示哪些附件没成功。
  final bool delivered;

  /// 成功上传并被带进本次投递的附件（文件名由服务端生成）。
  final List<QuickCaptureUpload> uploaded;

  /// 上传失败的附件（原始文件名 + 原因），供 UI 逐个提示。
  final List<QuickCaptureFailedUpload> failedUploads;

  /// 投递失败的原因（仅 [delivered] 为 false 时非空）。
  final SpbError? error;

  /// 是否有附件没能上传（但消息可能已发出）。
  bool get hasFailedUploads => failedUploads.isNotEmpty;

  @override
  String toString() =>
      'QuickCaptureEnqueueResult(delivered=$delivered, '
      'uploaded=${uploaded.length}, failed=${failedUploads.length})';
}

/// 一个上传失败的附件。
class QuickCaptureFailedUpload {
  const QuickCaptureFailedUpload({
    required this.filename,
    required this.reason,
  });

  final String filename;
  final String reason;

  @override
  String toString() => '$filename: $reason';
}

/// 无归属入口的**带附件**提交用例（走 mq-server 通用入站渠道）。
///
/// ## 与 QuickCaptureUseCase 的分工
///
/// | | [QuickCaptureUseCase] | 本类 |
/// |---|---|---|
/// | 端点 | `/me/quick-capture` | `/me/quick-capture/enqueue` |
/// | 附件 | ❌ | ✅ |
/// | 返回 | 归属 group（可导航） | 仅「已受理」 |
/// | 延迟 | 同步（请求内完成建 turn） | 异步（worker 消费后才建 turn） |
///
/// 需要「发完立刻跳到那个对话」的场景用前者（无附件）；需要附件时用本类，
/// 由调用方订阅 SSE 观察结果。
///
/// ## 为什么上传与投递在一个用例里（而不是让调用方各调一次）
///
/// 两步之间有一份**必须由调用方维护的中间状态**：上传得到的 `fileId` 要原样
/// 带进投递。若让 UI 自己串联，很容易出现「上传成功但忘了带 fileId」或
/// 「把展示用的文件名当成句柄传进去」这类错误。
///
/// 封进用例后，这条约束由类型保证：投递只接受 [QuickCaptureUpload.fileId]，
/// 调用方无从自行拼装投递请求。
///
/// ## 部分失败的处理
///
/// 单个附件上传失败**不阻断**整条消息：把成功的那些带上，失败的记进
/// [QuickCaptureEnqueueResult.failedUploads] 由 UI 提示。理由——用户拖了 3 个
/// 文件，其中 1 个超过服务端上限，因为这一个而整条消息发不出去，体验上更糟
/// （用户还得自己找出是哪一个）。
///
/// 但如果**全部**附件都失败且文本为空，则不投递（避免发一条空消息）。
class QuickCaptureEnqueueUseCase {
  QuickCaptureEnqueueUseCase(this._api);

  final ChatApi _api;

  /// 提交一句话（可带附件）。
  ///
  /// [input] 与 [attachments] **不能同时为空**——服务端会 400。调用方应先在
  /// UI 层拦住（禁用发送按钮），本方法也做一次防御性检查并返回未投递结果。
  ///
  /// [onUploadProgress] 在每个附件开始上传时回调（已完成数, 总数），供 UI
  /// 展示「正在上传 2/3」。它**不**报告字节级进度——服务端的 multipart 端点
  /// 没有提供进度反馈，假装有会让进度条卡在某个百分比。
  Future<QuickCaptureEnqueueResult> submit({
    String input = '',
    List<QuickCaptureAttachment> attachments = const [],
    void Function(int done, int total)? onUploadProgress,
  }) async {
    final text = input.trim();
    if (text.isEmpty && attachments.isEmpty) {
      return const QuickCaptureEnqueueResult(
        delivered: false,
        error: ValidationError('输入与附件不能同时为空'),
      );
    }

    final uploaded = <QuickCaptureUpload>[];
    final failed = <QuickCaptureFailedUpload>[];

    for (var i = 0; i < attachments.length; i++) {
      final att = attachments[i];
      onUploadProgress?.call(i, attachments.length);
      try {
        final up = await _api.uploadQuickCaptureAttachment(
          bytes: att.bytes,
          path: att.path,
          filename: att.filename,
          contentType: att.contentType,
        );
        if (!up.isValid) {
          // 服务端返回了 2xx 但缺 file_id：契约漂移。当作该附件失败，
          // 而不是把一个空值带进投递（那会 400 且错误信息指向附件标识，
          // 排查时很难联想到是响应解析问题）。
          SpbLog.warn('quick capture 附件上传响应缺 file_id', {
            'filename': att.filename,
          });
          failed.add(
            QuickCaptureFailedUpload(
              filename: att.filename,
              reason: '服务端未返回文件标识',
            ),
          );
          continue;
        }
        uploaded.add(up);
      } on SpbError catch (e) {
        // 单个附件失败不阻断整批：见类文档的说明。
        SpbLog.debug('quick capture 附件上传失败', {
          'filename': att.filename,
          'error': e.message,
        });
        failed.add(
          QuickCaptureFailedUpload(filename: att.filename, reason: e.message),
        );
      }
    }
    onUploadProgress?.call(attachments.length, attachments.length);

    // 全部附件失败且无文本 → 不投递。
    //
    // 为什么需要这个判断：服务端接受「有附件但无文本」，但它拿到的是**空**
    // 附件列表（我们没上传成功任何东西），于是会 400。与其发一个注定失败的
    // 请求，不如在这里短路，把失败原因如实交给 UI。
    if (text.isEmpty && uploaded.isEmpty && failed.isNotEmpty) {
      return QuickCaptureEnqueueResult(
        delivered: false,
        uploaded: uploaded,
        failedUploads: failed,
        error: const ValidationError('全部附件上传失败，消息未发送'),
      );
    }

    try {
      await _api.enqueueQuickCapture(
        input: text,
        attachments: uploaded.map((u) => u.fileId).toList(),
      );
    } on SpbError catch (e) {
      // ⚠️ 投递失败时**不能**把 uploaded 当作「已发送」——附件确实落在服务端
      // 暂存区了（但**不保证**会被自动清理，见 delivered 的说明），消息没有进队列。
      SpbLog.warn('quick capture 投递失败', {'error': e.message});
      return QuickCaptureEnqueueResult(
        delivered: false,
        uploaded: uploaded,
        failedUploads: failed,
        error: e,
      );
    }

    return QuickCaptureEnqueueResult(
      delivered: true,
      uploaded: uploaded,
      failedUploads: failed,
    );
  }
}

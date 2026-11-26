import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:uuid/uuid.dart';

import 'chat_stream_controller.dart';
import 'quick_capture_enqueue_usecase.dart';

/// 同一草稿重试复用上传结果与 request_id，避免响应丢失后重复建立 turn。
class ChatAttachmentSubmission {
  ChatAttachmentSubmission({
    required String input,
    required List<QuickCaptureAttachment> attachments,
  }) : input = input.trim().isEmpty ? '请查看附件。' : input.trim(),
       attachments = List.unmodifiable(attachments) {
    if (attachments.isEmpty || attachments.length > 10) {
      throw ArgumentError('一次请选择 1–10 个文件');
    }
  }

  final String input;
  final List<QuickCaptureAttachment> attachments;
  final String requestId = const Uuid().v4();
  final List<String> _uploaded = [];
  String? _groupId;
  String? _agentId;
  bool _sending = false;

  Future<void> send({
    required ChatApi api,
    required ChatStreamController controller,
    required String groupId,
    String? agentId,
  }) async {
    if (_sending) throw StateError('附件正在发送');
    if (groupId.isEmpty || (_groupId != null && _groupId != groupId)) {
      throw StateError('附件草稿所属对话已改变，请重新选择文件');
    }
    if (_groupId == null) {
      _groupId = groupId;
      _agentId = agentId;
    }
    _sending = true;
    try {
      for (var i = _uploaded.length; i < attachments.length; i++) {
        final file = attachments[i];
        final name = file.filename
            .split(RegExp(r'[/\\]'))
            .last
            .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_');
        if (name.isEmpty || name == '.' || name == '..') {
          throw ArgumentError('文件名无效');
        }
        // 每条消息独立目录，同名文件不会覆盖其他消息已引用的 UFS 内容。
        final result = await api.uploadWorkspaceFile(
          groupId: groupId,
          relativePath: 'uploads/$requestId/$i-$name',
          filename: name,
          path: file.path,
          bytes: file.bytes,
          contentType: file.contentType,
        );
        final id = result.fileId;
        if (result.groupId != groupId || id == null || id.isEmpty) {
          throw const ValidationError('上传响应缺少当前对话的文件信息');
        }
        _uploaded.add(id);
      }
      await controller.send(
        input: input,
        groupId: groupId,
        agentId: _agentId,
        routingMode: 'manual',
        requestId: requestId,
        fileContext: List.unmodifiable(_uploaded),
      );
    } finally {
      _sending = false;
    }
  }
}

/// user_message.payload.attachments 的公开投影，不接收服务端内部路径或正文。
class MessageAttachment {
  const MessageAttachment({
    required this.name,
    this.fileId,
    this.mimeType,
    this.sizeBytes,
    this.note,
  });

  final String name;
  final String? fileId;
  final String? mimeType;
  final int? sizeBytes;
  final String? note;

  static List<MessageAttachment> parseList(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable([
      for (final item in value)
        if (item is Map)
          MessageAttachment(
            name: item['name'] is String ? item['name'] as String : '附件',
            fileId: item['ufs_file_id'] is String
                ? item['ufs_file_id'] as String
                : null,
            mimeType: item['mime_type'] is String
                ? item['mime_type'] as String
                : null,
            sizeBytes: item['size_bytes'] is num
                ? (item['size_bytes'] as num).toInt()
                : null,
            note: item['note'] is String ? item['note'] as String : null,
          ),
    ]);
  }
}

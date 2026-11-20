import 'package:flutter/services.dart';
import 'package:cross_file/cross_file.dart';

import 'drag_drop.dart';

/// 系统分享与选中文字菜单的临时会话。宿主负责内容授权、缓存和返回来源应用。
class ExternalQuickCapture {
  const ExternalQuickCapture({
    required this.text,
    required this.files,
    this.error,
  });

  final String text;
  final List<DroppedFile> files;
  final String? error;
}

class ExternalQuickCaptureBridge {
  const ExternalQuickCaptureBridge();

  static const _channel = MethodChannel('com.atjog.spb/external_quick_capture');

  /// 普通 App 启动或不支持的平台返回 null，不改变应用内导航。
  Future<ExternalQuickCapture?> load() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('load');
      if (data == null) return null;
      return ExternalQuickCapture(
        text: data['text'] as String? ?? '',
        error: data['error'] as String?,
        files: [
          for (final file in (data['files'] as List? ?? const []))
            DroppedFile.fromXFile(
              XFile((file as Map)['path'] as String),
              name: file['name'] as String,
            ),
        ],
      );
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> finish() => _channel.invokeMethod<void>('finish');
}

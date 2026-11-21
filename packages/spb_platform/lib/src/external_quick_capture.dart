import 'package:flutter/services.dart';
import 'package:cross_file/cross_file.dart';

import 'drag_drop.dart';

/// 系统分享、选中文字与快捷设置的临时会话。宿主负责内容授权、缓存和返回来源应用。
class ExternalQuickCapture {
  const ExternalQuickCapture({
    required this.text,
    required this.files,
    this.error,
    this.readClipboard = false,
  });

  factory ExternalQuickCapture.fromMap(Map<String, dynamic> data) =>
      ExternalQuickCapture(
        text: data['text'] as String? ?? '',
        error: data['error'] as String?,
        readClipboard: data['readClipboard'] == true,
        files: [
          for (final file in (data['files'] as List? ?? const []))
            DroppedFile.fromXFile(
              XFile((file as Map)['path'] as String),
              name: file['name'] as String,
            ),
        ],
      );

  final String text;
  final List<DroppedFile> files;
  final String? error;

  /// 磁贴入口先渲染页面，待登录/解锁完成及窗口有焦点后才读取剪贴板。
  final bool readClipboard;
}

class ExternalQuickCaptureBridge {
  const ExternalQuickCaptureBridge();

  static const _channel = MethodChannel('com.atjog.spb/external_quick_capture');

  /// 普通 App 启动或不支持的平台返回 null，不改变应用内导航。
  Future<ExternalQuickCapture?> load() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('load');
      if (data == null) return null;
      return ExternalQuickCapture.fromMap(data);
    } on MissingPluginException {
      return null;
    }
  }

  Future<ExternalQuickCapture> readClipboard() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'readClipboard',
      );
      if (data != null) return ExternalQuickCapture.fromMap(data);
    } on PlatformException {
      // 平台异常不泄露来源内容，保留手动输入/粘贴的退路。
    } on MissingPluginException {
      // 宿主不支持时也应能进入普通草稿，不能停在加载页。
    }
    return const ExternalQuickCapture(
      text: '',
      files: [],
      error: '无法读取剪贴板，请长按输入框粘贴，或直接输入。',
    );
  }

  Future<void> finish() => _channel.invokeMethod<void>('finish');
}

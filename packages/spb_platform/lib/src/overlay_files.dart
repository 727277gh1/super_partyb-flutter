import 'package:flutter/services.dart';

import 'package:file_selector/file_selector.dart';
import 'package:spb_core/spb_core.dart';

import 'drag_drop.dart';

/// 悬浮输入窗的「添加文件」入口。
///
/// ## 为什么与拖拽分开放
///
/// 拖拽（[DragDropCapability]）是**被动的**——平台推事件给我们；文件选择是
/// **主动的**——我们去调系统对话框。两者的失败模式不同：拖拽失败通常无声
/// （用户拖错东西），文件选择失败需要给用户反馈（对话框打不开）。故不塞进
/// 同一个接口。
///
/// ## 为什么不放在 UI 层直接调 file_selector
///
/// 与 [DragDropCapability] 同一理由：`spb_features` 不应依赖平台插件。
/// 移动端会走 `NoopDragDropCapability` 那条路（没有「拖入」，但有系统文件
/// 选择器，所以本函数在移动端**仍然可用**）。
Future<List<DroppedFile>> pickFilesForOverlay() async {
  try {
    final files = await openFiles(confirmButtonText: '添加');
    if (files.isEmpty) return const [];
    return files.map(DroppedFile.fromXFile).toList();
  } on Object catch (e) {
    // 平台不支持 / 无 DISPLAY / 用户取消：静默返回空。
    // 与 DirectoryPicker 同一约定——「没有选择器」与「用户取消」都是
    // 预期内结果，不该让 UI 写 try/catch。
    SpbLog.warn('打开文件选择器失败', {'error': '$e'});
    return const [];
  }
}

/// 从剪贴板读取文件（图片/文件粘贴）。
///
/// ## 为什么需要它
///
/// 桌面端用户截图后最自然的动作是 `Ctrl+V`，而不是「保存到磁盘再拖进来」。
/// 缺这条路径会让「截图提问」这个高频场景多两步操作。
///
/// ## 为什么用 platform channel 而不是 Clipboard.getData
///
/// Flutter 的 `Clipboard` 只暴露**文本**（`Clipboard.getData` 返回
/// `ClipboardData`，其中只有 `text`）。剪贴板里的位图/文件列表要走各平台
/// 的原生 API。这里调用一个约定好的 channel；**未实现时静默返回空**
/// （见下方说明），不影响文本粘贴。
///
/// ## 平台实现的现状
///
/// 本函数只定义契约与降级路径：channel 未注册时返回空列表（`MissingPluginException`
/// 被捕获）。各平台的真实实现在 `apps/*/` 的原生侧，属于独立工作项——
/// 在它落地前，本函数的行为是「静默无操作」，用户仍可拖拽或点击添加。
Future<List<DroppedFile>> readClipboardFiles() async {
  try {
    const channel = MethodChannel('com.atjog.spb/clipboard_files');
    final raw = await channel.invokeMethod<List<Object?>>('readFiles');
    if (raw == null || raw.isEmpty) return const [];
    final out = <DroppedFile>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = (item['name'] ?? '').toString();
      final bytes = item['bytes'];
      if (name.isEmpty || bytes is! List) continue;
      out.add(DroppedFile.fromBytes(name: name, bytes: bytes.cast<int>()));
    }
    return out;
  } on MissingPluginException {
    // 平台尚未实现：正常降级（文本粘贴不受影响）。
    SpbLog.debug('剪贴板文件读取未实现，降级为无操作');
    return const [];
  } on PlatformException catch (e) {
    SpbLog.warn('读取剪贴板文件失败', {'error': e.message});
    return const [];
  }
}

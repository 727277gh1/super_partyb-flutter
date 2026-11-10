import 'package:file_selector/file_selector.dart';
import 'package:spb_core/spb_core.dart';

import 'desktop_capabilities.dart';

/// 基于 `file_selector` 的目录选择器。
///
/// ## 为什么单独一个类而不是塞进 `bootstrap.dart` 的
/// `_PlatformDesktopCapabilities`
///
/// `_PlatformDesktopCapabilities` 是 M0 阶段的骨架（窗口/托盘/快捷键都还是
/// TODO）。目录选择是**已经能真正工作**的一项，且它的行为（用户取消、
/// 平台不支持）需要被同步页依赖。拆出来让它可以被单测注入假实现，
/// 而不必拖着一堆未实现的窗口逻辑。
///
/// ## 为什么平台不支持时返回 null 而不是抛异常
///
/// 见 [DesktopCapabilities.pickDirectory] 的说明：「用户取消」与「没有目录
/// 选择器」都是预期内结果，异常语义是「出错了」。
class FileSelectorDirectoryPicker {
  const FileSelectorDirectoryPicker();

  /// 弹出系统目录选择对话框。
  ///
  /// [title] 是对话框标题（部分平台忽略它）。
  Future<String?> pick({String? title}) async {
    try {
      final path = await getDirectoryPath(
        // 未提供 title 时传空串而非 null：`getDirectoryPath` 的
        // `confirmButtonText` 为空时由平台给默认文案。
        confirmButtonText: '选择此目录',
      );
      // 平台返回空串等同于取消（Linux 实现偶尔会这样）。
      if (path == null || path.isEmpty) return null;
      return path;
    } catch (e) {
      // 目录选择器不可用（如无 DISPLAY 的服务器、缺少 GTK 端口）：
      // 静默降级为「取消」并记日志，不让上层为「没有 GUI」写 try/catch。
      SpbLog.warn('打开目录选择器失败', {'error': e.toString()});
      return null;
    }
  }
}

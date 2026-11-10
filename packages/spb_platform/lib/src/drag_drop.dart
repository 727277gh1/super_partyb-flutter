import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';
import 'package:spb_core/spb_core.dart';

/// 拖入/选中的文件（已归一成「文件名 + 惰性读取」）。
///
/// ## 为什么保留惰性而不是立刻读成字节
///
/// 拖入可能是几个几百 MB 的文件。在拖拽事件里同步读完会卡住 UI 线程，而用户
/// 可能只是误拖。故本类只持有**读取能力**，真正读字节发生在提交时。
///
/// ## 为什么 `length()` 与 `readBytes()` 都可能抛
///
/// 文件可能在「拖入」与「提交」之间被删除/移动。调用方必须处理这个异常
/// （提示用户重新拖入），而不是假设读取一定成功。
class DroppedFile {
  // Why 不用 initializing formal：Dart 不允许**私有命名参数**
  // （`this._length` 会让调用方必须写 `_length:`，编译器直接拒绝）。
  // 故只能用公开名 + 显式赋值。lint 在这里的提示是误报。
  // ignore_for_file: prefer_initializing_formals
  DroppedFile._({
    required this.name,
    required this.path,
    required Future<int> Function() length,
    required Future<List<int>> Function() readBytes,
  }) : _length = length,
       _readBytes = readBytes;

  /// 文件名（含扩展名，不含路径）。
  final String name;

  /// 本地绝对路径；内存来源（剪贴板/字节）为 null。
  ///
  /// ## 为什么要暴露它
  ///
  /// 有路径时上传层可以从磁盘**流式**读取，内存里不出现第二份副本。若只
  /// 暴露 `readBytes()`，调用方就只能先把整个文件读进内存——50 MiB 的文件
  /// 在用户等待的同步上传路径上会存两份。
  ///
  /// 与 [readBytes] 同一约定：路径可能在拖入后被删除/移动，读取时才报错。
  final String? path;

  final Future<int> Function() _length;
  final Future<List<int>> Function() _readBytes;

  /// 字节数。可能抛（文件已不存在）。
  Future<int> length() => _length();

  /// 读取内容。多次调用会重复读（不缓存：大文件缓存会占内存）。
  Future<List<int>> readBytes() => _readBytes();

  /// 从 `XFile` 构造。
  ///
  /// `desktop_drop` 的 `DropItem` 继承自 `XFile`，故拖拽与文件选择走同一入口。
  static DroppedFile fromXFile(XFile file) {
    return DroppedFile._(
      name: _basename(file.name.isEmpty ? file.path : file.name),
      // XFile.path 对磁盘来源是绝对路径；对「内存构造」的 XFile 是空串。
      // 空串归一成 null，否则上传层会拿空路径去打开文件。
      path: file.path.isEmpty ? null : file.path,
      length: file.length,
      readBytes: file.readAsBytes,
    );
  }

  /// 从 `DropItem` 构造（`desktop_drop` 的拖拽事件类型）。
  ///
  /// ## 为什么直接用 `DropItem` 而不是自己解析路径
  ///
  /// 平台差异（Linux 的 `file://` URI、Windows 的 `\\?\` 前缀、macOS 的文件
  /// 承诺）都由 `desktop_drop` 内部处理。自己解析路径字符串会在某个平台上出错，
  /// 而这类错误只在那个平台复现。
  static DroppedFile fromDropItem(DropItem item) => fromXFile(item);

  /// 从原始字节构造（剪贴板粘贴、测试）。
  static DroppedFile fromBytes({
    required String name,
    required List<int> bytes,
  }) {
    final copy = List<int>.unmodifiable(bytes);
    return DroppedFile._(
      name: _basename(name),
      // 字节来源没有路径：上传层会回退到把字节交给 multipart。
      path: null,
      length: () async => copy.length,
      readBytes: () async => copy,
    );
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final i = normalized.lastIndexOf('/');
    return i >= 0 ? normalized.substring(i + 1) : normalized;
  }

  @override
  String toString() => 'DroppedFile($name)';
}

/// 拖拽能力。
///
/// ## 为什么要有这层抽象
///
/// `desktop_drop` 在移动端没有实现（拖拽是桌面交互）。若 UI 直接 import 它，
/// 移动端会拿到一个「能编译但永远收不到事件」的组件——用户看不出问题，
/// 代码里却多了一条死路径。用接口隔离后，UI 只需判 [isSupported]。
///
/// 与 [DesktopCapabilities] 同一约定：**不支持时静默降级**，不抛异常。
abstract interface class DragDropCapability {
  /// 当前平台是否支持文件拖入（仅桌面端为 true）。
  bool get isSupported;

  /// 把子树包成拖拽接收区。
  ///
  /// [onFiles] 在用户放下文件时回调。不支持的平台上原样返回 [child]，
  /// 不产生额外 widget 层级。
  Widget buildDropZone({
    required Widget child,
    required void Function(List<DroppedFile> files) onFiles,
    void Function(bool hovering)? onHoverChanged,
  });
}

/// 桌面端实现（基于 `desktop_drop`）。
class DesktopDragDropCapability implements DragDropCapability {
  const DesktopDragDropCapability();

  @override
  bool get isSupported => true;

  @override
  Widget buildDropZone({
    required Widget child,
    required void Function(List<DroppedFile> files) onFiles,
    void Function(bool hovering)? onHoverChanged,
  }) {
    return DropTarget(
      onDragEntered: (_) => onHoverChanged?.call(true),
      onDragExited: (_) => onHoverChanged?.call(false),
      onDragDone: (detail) {
        // 先通知「离开」，否则高亮会一直留着：某些平台在「拖入后又拖走、
        // 未放下」时不触发 onDragExited。
        onHoverChanged?.call(false);
        final files = detail.files.map(DroppedFile.fromDropItem).toList();
        if (files.isEmpty) {
          // 拖的是文本/链接而非文件。这类拖拽与文件拖拽共用同一事件通道，
          // 属于正常情况，忽略即可（不报错、不提示）。
          SpbLog.debug('拖拽事件不含文件，忽略');
          return;
        }
        onFiles(files);
      },
      child: child,
    );
  }
}

/// 移动端/不支持平台的空实现。
class NoopDragDropCapability implements DragDropCapability {
  const NoopDragDropCapability();

  @override
  bool get isSupported => false;

  @override
  Widget buildDropZone({
    required Widget child,
    required void Function(List<DroppedFile> files) onFiles,
    void Function(bool hovering)? onHoverChanged,
  }) => child;
}

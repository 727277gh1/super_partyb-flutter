import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // 剪贴板文件读取通道（`com.atjog.spb/clipboard_files`）。
  //
  // ## ⚠️ 通道名必须与 Dart 侧逐字一致
  //
  // packages/spb_platform/lib/src/overlay_files.dart 的
  // `MethodChannel('com.atjog.spb/clipboard_files')`。写错不会报错，只会
  // 表现为 Dart 侧收到 MissingPluginException 并静默降级——即「Ctrl+V 没
  // 反应」，与「平台根本没实现」完全无法区分。三端（Linux / Windows /
  // macOS）同理。
  //
  // 持有为属性：与 Linux / Windows 侧同一做法，让「通道是否还活着」显式。
  //
  // 注：释放通道**不会**注销 handler——`FlutterMethodChannel` 没有实现
  // `dealloc`，handler 由 messenger 持有（见 FlutterChannels.mm 的
  // `setMethodCallHandler:`）。故这里持有它是为了可读性与将来显式注销的
  // 余地，不是因为不持有就会失效。
  private var clipboardChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    registerClipboardFilesChannel()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // MARK: - 剪贴板文件读取

  /// 注册通道。
  ///
  /// ## 为什么取 messenger 要绕 `mainFlutterWindow.contentViewController`
  ///
  /// `FlutterAppDelegate` 不持有 engine，engine 挂在 FlutterViewController 上
  /// （`FlutterViewController.engine.binaryMessenger`）。`mainFlutterWindow`
  /// 是 MainMenu.xib 连过来的 IBOutlet，而 MainFlutterWindow.awakeFromNib
  /// 在 nib 加载时就建好了 controller——主 nib 的加载发生在
  /// `applicationDidFinishLaunching` 之前，故这里一定拿得到。
  ///
  /// 拿不到时**静默跳过**：Dart 侧本就把「通道未注册」当正常降级（文本粘贴
  /// 不受影响），不该为了一个可选能力让应用起不来。
  private func registerClipboardFilesChannel() {
    guard
      let controller = mainFlutterWindow?.contentViewController
        as? FlutterViewController
    else {
      NSLog("剪贴板文件通道未注册：取不到 FlutterViewController")
      return
    }

    let channel = FlutterMethodChannel(
      name: "com.atjog.spb/clipboard_files",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      // 用 `guard let` 而不是 `self?.`：后者在 self 已释放时**不会调用
      // result**，Dart 侧的 `await invokeMethod` 会永远挂住（表现为粘贴
      // 卡死，比报错更难查）。self 是 AppDelegate，实践中活到进程结束，
      // 但把「必须恰好回复一次」这个约定写死比依赖生命周期更稳。
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    clipboardChannel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "readFiles" else {
      result(FlutterMethodNotImplemented)
      return
    }
    // 「没有文件」返回**空列表**而不是错误：Dart 侧把空列表当作「剪贴板里
    // 没有文件，降级为文本粘贴」（见 overlay_files.dart 的
    // readClipboardFiles）。若这里回 error，用户从网页复制一段文字再 Ctrl+V
    // 就会看到一条失败提示——而那是完全正常的操作。
    result(readClipboardFileEntries())
  }

  /// 单文件读取上限（OOM 兜底）。
  ///
  /// Dart 侧真正的策略上限是 kOverlayMaxAttachmentBytes = 50 MiB，但那个判断
  /// 发生在字节**已经读进内存之后**。剪贴板里可能是一份 GB 级的镜像，直接
  /// `Data(contentsOf:)` 会把进程推向内存耗尽。与 Linux / Windows 侧同值。
  private static let maxFileBytes: UInt64 = 512 * 1024 * 1024

  /// 读剪贴板里的文件 URL 并组装成 Dart 侧期望的 `[{name, bytes}]`。
  ///
  /// ## 为什么是 `readObjects(forClasses: [NSURL.self])`
  ///
  /// 文件在剪贴板上放的是 file URL（对应 Linux 的 `text/uri-list`、Windows 的
  /// `CF_HDROP`）。取 `NSPasteboard.PasteboardType.fileURL` 只能拿到**一个**
  /// URL 的 Data 表示，多选时拿不全；`readObjects` 返回全部，且
  /// `.urlReadingFileURLsOnly` 帮我们滤掉非文件 URL（http 链接等）。
  ///
  /// ## 沙箱下的文件访问
  ///
  /// 应用开了 `com.apple.security.app-sandbox`。用户从 Finder 复制/拖入的
  /// 文件由系统自动授予临时访问权（pasteboard 的 security scope），故这里
  /// 不需要额外的 user-selected 读权限。若将来发现某些来源读不到，那属于
  /// entitlements 的调整范围，不在本函数的职责内。
  private func readClipboardFileEntries() -> [[String: Any]] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]
    guard
      let urls = NSPasteboard.general.readObjects(
        forClasses: [NSURL.self],
        options: options
      ) as? [URL]
    else {
      // 剪贴板里是纯文本 / 图片 / 空：没有文件 URL。这是**正常**情况。
      return []
    }

    var entries: [[String: Any]] = []
    for url in urls {
      // 单项失败（超限 / 不可读 / 是目录）不影响其余 URL。
      if let entry = readFileEntry(at: url) {
        entries.append(entry)
      }
    }
    return entries
  }

  /// 读一个本地文件并组装成 `{name, bytes}`；失败返回 nil。
  private func readFileEntry(at url: URL) -> [String: Any]? {
    // 先查大小再读内容：超限时**根本不读**，否则上限就形同虚设
    // （判断发生在字节已进内存之后）。
    //
    // 用 Int 比较而不转 UInt64：fileSize 理论上非负，但若平台返回负数，
    // `UInt64(size)` 会**直接陷阱崩溃**（不是返回 nil）。比较不需要转换。
    guard
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
      size >= 0,
      size <= Int(Self.maxFileBytes)
    else {
      NSLog("剪贴板文件不可读或超过上限，跳过 %@", url.path)
      return nil
    }

    // `.mappedIfSafe` 对普通文件仍是普通读；用它是因为大文件下比逐字节拷贝
    // 省一次内存复制。失败（权限不足 / 读一半被删 / 是目录）时跳过该项。
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      return nil
    }

    return [
      "name": url.lastPathComponent,
      // FlutterStandardTypedData(bytes:) 走标准编解码的 ByteList 分支，
      // 到 Dart 侧就是 Uint8List——正是契约要求的 `bytes: List<int>`。
      "bytes": FlutterStandardTypedData(bytes: data),
    ]
  }
}

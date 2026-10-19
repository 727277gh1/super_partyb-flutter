#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// 剪贴板文件读取通道名。
//
// ⚠️ 必须与 Dart 侧逐字一致：packages/spb_platform/lib/src/overlay_files.dart
// 的 `MethodChannel('com.atjog.spb/clipboard_files')`。写错不会报错，只会
// 表现为 Dart 侧收到 MissingPluginException 并静默降级——即「粘贴没反应」，
// 与「平台根本没实现」完全无法区分。三端（Linux / Windows / macOS）同理。
constexpr char kClipboardFilesChannelName[] = "com.atjog.spb/clipboard_files";

// 单文件读取上限（OOM 兜底）。
//
// Dart 侧真正的策略上限是 kOverlayMaxAttachmentBytes = 50 MiB，但那个判断
// 发生在字节**已经读进内存之后**。剪贴板里可能是一份 GB 级的镜像，直接全量
// 读会把进程推向 OOM——Windows 上通常表现为提交内存耗尽后崩溃，而不是干净地
// 返回一个错误。
//
// 这里只是一个远高于正常附件大小的兜底值，不是产品策略；超过就跳过该项并
// 告警，让用户改用「添加文件」按钮走流式上传。与 Linux 侧同值。
constexpr ULONGLONG kClipboardMaxFileBytes = 512ULL * 1024 * 1024;

// 取路径的最后一段（文件名）。
//
// 手写扫描而不是 `PathFindFileNameW`：后者要额外链接 shlwapi.lib，而这里
// 只需处理两个分隔符。同时接受 `\` 与 `/`——Windows API 两者都认。
std::wstring BaseName(const std::wstring& path) {
  const size_t pos = path.find_last_of(L"\\/");
  return pos == std::wstring::npos ? path : path.substr(pos + 1);
}

// UTF-16 文件名 → UTF-8。
//
// ## 为什么必须转而不能直接传 std::wstring
//
// `EncodableValue` 的 variant 里**没有** `std::wstring`（见 encodable_value.h
// 的类型表），只有 `std::string`。直接构造会编译失败。
//
// 而路径必须用宽字符读（Windows 文件名可以是任意 UTF-16），故在**交给
// Dart 之前**转一次：文件名跨进程边界时统一成 UTF-8，Dart 侧拿到的是正确
// 的 String，不需要平台知识。
//
// ## 为什么复用 utils 里的 Utf8FromUtf16 而不是自己写
//
// 那个函数已经在 runner 里（`GetCommandLineArguments` 用它转命令行参数），
// 且带 CWE-126 的长度上界与 `WC_ERR_INVALID_CHARS` 处理。再抄一份只会让
// 两处的边界行为漂移。
std::string Utf8FileName(const std::wstring& path) {
  const std::wstring name = BaseName(path);
  return Utf8FromUtf16(name.c_str());
}

// 读一个本地文件并组装成 Dart 侧期望的 {name, bytes} 条目；失败返回 nullopt。
//
// ## 为什么用 Win32 而不是 std::ifstream
//
// 路径是宽字符（Windows 文件名可以是任意 UTF-16，含 ANSI 代码页表达不了的
// 字符）。窄字符 `std::ifstream` 在非 Unicode 代码页下会打不开这类文件，
// 且失败原因（打不开 vs 读失败）无法区分。Win32 API 全程宽字符，无此问题。
std::optional<flutter::EncodableValue> ClipboardReadFileEntry(
    const std::wstring& path) {
  // 共享模式放开读写删：剪贴板里的文件可能正被别的进程占用（例如看图器
  // 打开着刚复制的那张图）。只请求 GENERIC_READ，不独占。
  HANDLE file = ::CreateFileW(
      path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    // 权限不足 / 已删除 / 是目录（CreateFile 对目录也会失败，因为没带
    // FILE_FLAG_BACKUP_SEMANTICS）：跳过该项，不拖垮整批。
    return std::nullopt;
  }

  LARGE_INTEGER size = {};
  if (!::GetFileSizeEx(file, &size)) {
    ::CloseHandle(file);
    return std::nullopt;
  }

  if (size.QuadPart > static_cast<LONGLONG>(kClipboardMaxFileBytes)) {
    ::CloseHandle(file);
    return std::nullopt;
  }

  std::vector<uint8_t> bytes(static_cast<size_t>(size.QuadPart));
  if (!bytes.empty()) {
    DWORD read = 0;
    // 单次 ReadFile 即可：bytes.size() 已被上限约束在 512 MiB 以内，远小于
    // DWORD 上限，不需要循环。
    if (!::ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read,
                    nullptr)) {
      ::CloseHandle(file);
      return std::nullopt;
    }
    // 文件可能在 GetFileSizeEx 之后被截短：按实际读到的长度收缩，避免把
    // 尾部的一串 0 当成文件内容发给服务端。
    bytes.resize(read);
  }
  ::CloseHandle(file);

  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("name"),
       flutter::EncodableValue(Utf8FileName(path))},
      // std::vector<uint8_t> → Dart Uint8List（见 encodable_value.h 的类型映射）。
      {flutter::EncodableValue("bytes"), flutter::EncodableValue(bytes)},
  });
}

// 读剪贴板里的文件路径列表。
//
// ## 为什么是 CF_HDROP
//
// 资源管理器里 Ctrl+C 一个文件时，剪贴板放的是 CF_HDROP（一个 DROPFILES
// 结构，内含双 NUL 结尾的路径列表）。它对应 Linux 侧的 `text/uri-list`。
// 取纯文本（CF_UNICODETEXT）拿到的是拼好的字符串且丢失「这是文件」的语义，
// 无法区分「复制了文件」与「复制了看起来像路径的文本」。
//
// ## 为什么返回 nullopt 而不是空列表
//
// 调用方据此区分「剪贴板里没有文件」（空列表，正常降级）与「读不到剪贴板」
// ——两者对 Dart 侧的处理相同（都降级为文本粘贴），但日志与调试时的语义不同。
std::optional<std::vector<std::wstring>> ClipboardReadPaths() {
  if (!::IsClipboardFormatAvailable(CF_HDROP)) {
    // 剪贴板里是纯文本 / 图片 / 空：没有文件列表。这是**正常**情况，不是错误。
    return std::vector<std::wstring>{};
  }

  // 剪贴板是全局独占资源，另一个进程持有它时 OpenClipboard 会失败。这不是
  // 异常（用户可能刚在别的程序里复制），失败就当作「没有文件」。
  if (!::OpenClipboard(nullptr)) {
    return std::nullopt;
  }

  std::vector<std::wstring> paths;
  if (HANDLE data = ::GetClipboardData(CF_HDROP)) {
    // ⚠️ 这个 HANDLE 归剪贴板所有，**不得** GlobalFree；用完 CloseClipboard
    // 即可。故这里在 CloseClipboard 之前把路径复制进 std::wstring。
    HDROP drop = static_cast<HDROP>(data);
    // 索引 0xFFFFFFFF 表示「查询文件个数」。
    const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; ++i) {
      // 先问长度再取内容：DragQueryFileW 返回的是不含结尾 NUL 的字符数。
      const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
      if (length == 0) {
        continue;  // 空项：跳过，不影响其余路径
      }
      std::wstring buffer(length + 1, L'\0');
      if (::DragQueryFileW(drop, i, buffer.data(), length + 1) != 0) {
        buffer.resize(length);
        paths.push_back(std::move(buffer));
      }
    }
  }

  ::CloseClipboard();
  return paths;
}

// 通道方法分发。
void ClipboardMethodCallHandler(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "readFiles") {
    result->NotImplemented();
    return;
  }

  // ## 为什么「没有文件」返回空列表而不是错误
  //
  // Dart 侧把空列表当作「剪贴板里没有文件，降级为文本粘贴」（见
  // overlay_files.dart 的 readClipboardFiles）。若这里回 error，用户从网页
  // 复制一段文字再 Ctrl+V 就会看到一条失败提示——而那是完全正常的操作。
  flutter::EncodableList entries;
  if (auto paths = ClipboardReadPaths()) {
    for (const std::wstring& path : *paths) {
      if (auto entry = ClipboardReadFileEntry(path)) {
        entries.push_back(std::move(*entry));
      }
      // 单项失败（超限 / 不可读）不影响其余路径。
    }
  }
  result->Success(flutter::EncodableValue(entries));
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 剪贴板文件读取通道。
  //
  // 时机放在 RegisterPlugins 之后：两者都需要从 engine 取 messenger，放在
  // 这里是为了与插件注册保持同一个「引擎已就绪」的前提，避免将来调整顺序
  // 时踩坑。
  //
  // 通道对象由本对象持有：messenger 内部也会持有 handler，但依赖那一层会让
  // 「通道是否还活着」变得不显式，自己持有一份更清楚（同 Linux 侧的做法）。
  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          kClipboardFilesChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(ClipboardMethodCallHandler);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 先释放通道再释放 controller：通道持有 engine 的 messenger 指针，
  // 顺序反了会留下一个指向已析构 engine 的悬垂指针。
  clipboard_channel_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

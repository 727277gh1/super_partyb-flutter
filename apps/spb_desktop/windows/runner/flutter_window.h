#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 剪贴板文件读取通道（`com.atjog.spb/clipboard_files`）。
  //
  // 由 OnCreate 创建、OnDestroy 释放（**先于** flutter_controller_，
  // 见 OnDestroy 里的顺序说明）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_channel_;

  // 宿主生命周期通道（`com.atjog.spb/host_lifecycle`，原生 → Dart）。
  //
  // 目前只有一个出站动作：`sessionEnding`——Windows 的 Restart Manager
  // 要求本进程退出（安装包升级 / 卸载）时通知 Dart 走正常退出路径。
  // 见 MessageHandler 里的说明。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      host_lifecycle_channel_;

  // 是否已收到「会话确实要结束」（WM_ENDSESSION 且 lParam 含
  // ENDSESSION_CLOSEAPP）。只有它为真时才放行 WM_CLOSE——否则用户点关闭的
  // 既有行为（隐藏到托盘）会被破坏。
  bool session_ending_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

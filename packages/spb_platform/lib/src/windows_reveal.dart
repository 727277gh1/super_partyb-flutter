/// Windows「在文件管理器中选中条目」的**原生**实现
/// （`SHParseDisplayName` + `SHOpenFolderAndSelectItems`）。
///
/// ## 为什么 `explorer /select,<path>` 不够（issue #97）
///
/// 命令行形态有两个**用 `Process.run` 表达不出来**的限制：
///
/// 1. **含空格路径的引号位置**：explorer 要求 `/select,"C:\a b\f.md"`
///    （引号只包路径），而 `Process.run` 会把**整个 argv** 加引号 →
///    `"/select,C:\a b\f.md"`。格式错了它不报错，静默打开「此电脑」。
/// 2. **分隔符歧义**：混合分隔符（`C:\dir/file.md`）被 explorer 当成无效参数
///    ——`dart:io` 宽容、explorer 不宽容，见 `system_open.dart` 的
///    `normalizeWindowsPath`。
///
/// `SHOpenFolderAndSelectItems` 是资源管理器自己「打开文件所在的位置」用的
/// API：直接吃 PIDL，中间没有命令行解析这一层，两种问题都不存在。
///
/// ## 分层
///
/// 只依赖 `dart:ffi` / `package:ffi` / `spb_core`，**不 import
/// `package:flutter`**——与 `system_open.dart` 同一取向。平台分派的唯一实现
/// 仍在 `system_open.dart`，本文件只是它的 Windows 后端。
///
/// ## ⚠️ 非 Windows 上不可用（这是**有意**的降级路径）
///
/// `DynamicLibrary.open('shell32.dll')` 在 Linux/macOS/移动端抛错。调用方
/// （`spawnSystemReveal` 的 Windows 分支）用 try/catch 兜住并回退
/// `explorer /select,`，故：
///
/// - **不要**在构造函数里打开库。库句柄是 `static final`，Dart 的静态变量
///   惰性初始化——本文件在 Linux CI 里可以安全构造（测试要注入假实现时连
///   构造都省了），只有真的走到 `reveal()` 才会尝试加载 `shell32.dll`。
/// - 这也让「Linux 上跑 Windows 分支的单测」天然覆盖**降级路径**：真实后端
///   打不开库 → 回退命令行形态 → 断言依旧成立。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:spb_core/spb_core.dart';

/// Windows「在资源管理器中选中条目」的底层实现（可注入）。
///
/// 抽成接口的理由与 [ProcessRunner]（`system_open.dart`）相同：真实实现只能
/// 在 Windows 上跑，而调用方的**降级顺序**（原生失败 → `explorer /select,`）
/// 必须能在 Linux CI 里逐条断言。
abstract interface class WindowsRevealBackend {
  /// 在资源管理器中定位 [nativePath]。
  ///
  /// [nativePath] 由调用方**归一化为 Windows 原生分隔符**（见
  /// `normalizeWindowsPath`）——本层不再处理分隔符。
  ///
  /// 返回 true 表示已成功发起。**允许抛异常**：调用方用 try/catch 兜住并回退
  /// 命令行形态。「不可用」（非 Windows、DLL 缺失）与「失败」（HRESULT 非
  /// S_OK）在调用方是同一处理，故不额外区分。
  Future<bool> reveal(String nativePath);
}

/// 真实实现：`SHParseDisplayName` + `SHOpenFolderAndSelectItems`（shell32）。
///
/// ## 为什么传「条目自身」的 PIDL 而不是父目录
///
/// `SHOpenFolderAndSelectItems(pidlFolder, cidl, apidl, flags)` 有两种用法：
/// 传父目录 + 子项数组（需要 `SHGetIDListFromObject` 之类额外步骤），或
/// **传条目自身的 PIDL 且 `cidl = 0`**——后者是文档里的等价写法，也是唯一
/// 不需要知道父目录的形态（本层拿不到「父目录 + 文件名」的拆分，也不想为了
/// 它再引一次路径解析）。
class Shell32RevealBackend implements WindowsRevealBackend {
  const Shell32RevealBackend();

  @override
  Future<bool> reveal(String nativePath) async {
    final pathPtr = nativePath.toNativeUtf16();
    final pidlOut = calloc<Pointer<Void>>();
    var comInitialized = false;
    var pidlValid = false;
    try {
      // `SHOpenFolderAndSelectItems` 要求调用线程已初始化 COM。Flutter 的
      // platform thread 通常已由 embedder 初始化（`CoInitializeEx` 返回
      // S_FALSE = 早就初始化过）；S_OK 说明是本次初始化的，退出时要
      // `CoUninitialize` 配对，否则会把别人的初始化引用计数减掉。
      //
      // RPC_E_CHANGED_MODE（线程已被按 MTA 初始化）不配对、也不放弃：这几个
      // shell API 不要求 STA，直接调用即可。
      final hrInit = _coInitializeEx(
        nullptr,
        _coinitApartmentThreaded | _coinitDisableOle1Dde,
      );
      if (hrInit == _sOk || hrInit == _sFalse) comInitialized = true;

      final hrParse = _parseDisplayName(pathPtr, nullptr, pidlOut, 0, nullptr);
      if (hrParse != _sOk) {
        // 最常见原因：路径不存在（上层虽已探测过，但探测与 spawn 之间文件
        // 可能被删）。回 false 让调用方回退命令行形态——那边同样会失败，
        // 但日志里能看到两条线索，便于区分「路径问题」与「API 问题」。
        SpbLog.warn('SHParseDisplayName 失败，无法定位条目', {
          'path': nativePath,
          'hr': _hex(hrParse),
        });
        return false;
      }
      pidlValid = true;

      final hrSelect = _openFolderAndSelectItems(pidlOut.value, 0, nullptr, 0);
      if (hrSelect != _sOk) {
        SpbLog.warn('SHOpenFolderAndSelectItems 失败', {
          'path': nativePath,
          'hr': _hex(hrSelect),
        });
        return false;
      }
      return true;
    } finally {
      // 顺序：先释放 PIDL（仅解析成功才有），再释放宿主内存，最后 COM 配对。
      if (pidlValid) _ilFree(pidlOut.value);
      calloc.free(pidlOut);
      calloc.free(pathPtr);
      if (comInitialized) _coUninitialize();
    }
  }

  /// HRESULT 一律按 32 位无符号打印：失败值是 `0x8007xxxx` 这类高位为 1 的
  /// 有符号负数，直接打出来是 `-2147…`，对着 MSDN 查不到。
  static String _hex(int hr) =>
      '0x${hr.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';

  // ---------------------------------------------------------------------------
  // 绑定。全部 static final → 首次访问才加载（见文件头的「非 Windows」说明）。
  // ---------------------------------------------------------------------------

  static final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
  static final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');

  /// `HRESULT SHParseDisplayName(LPCWSTR, IBindCtx*, PIDLIST_ABSOLUTE*,
  /// SFGAOF, SFGAOF*)`。
  static final int Function(
    Pointer<Utf16>,
    Pointer<Void>,
    Pointer<Pointer<Void>>,
    int,
    Pointer<Uint32>,
  )
  _parseDisplayName = _shell32
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          int,
          Pointer<Uint32>,
        )
      >('SHParseDisplayName');

  /// `HRESULT SHOpenFolderAndSelectItems(PCIDLIST_ABSOLUTE, UINT,
  /// PCUITEMID_CHILD_ARRAY, DWORD)`。
  static final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int)
  _openFolderAndSelectItems = _shell32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int)
      >('SHOpenFolderAndSelectItems');

  /// `void ILFree(PIDLIST_ABSOLUTE)`（shell32 的导出名就叫 `ILFree`）。
  static final void Function(Pointer<Void>) _ilFree = _shell32
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('ILFree');

  /// `HRESULT CoInitializeEx(LPVOID, DWORD)`。
  static final int Function(Pointer<Void>, int) _coInitializeEx = _ole32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('CoInitializeEx');

  /// `void CoUninitialize(void)`。
  static final void Function() _coUninitialize = _ole32
      .lookupFunction<Void Function(), void Function()>('CoUninitialize');

  static const int _sOk = 0;
  static const int _sFalse = 1;

  /// `COINIT_APARTMENTTHREADED`：与 Flutter embedder 的线程模型一致。
  static const int _coinitApartmentThreaded = 0x2;

  /// `COINIT_DISABLE_OLE1DDE`：本层不用 DDE，顺手省一点初始化开销。
  static const int _coinitDisableOle1Dde = 0x4;
}

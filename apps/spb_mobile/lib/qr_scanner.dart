import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_platform/spb_platform.dart';

/// 按平台构造相机扫码能力。
///
/// 只有移动端有相机（`mobile_scanner` 支持 Android/iOS/macOS）；
/// 桌面端注入 [NoopQrScanner]，登录页据此不渲染「扫一扫」入口
/// （`isSupported` 为 false → 宿主不传回调 → 入口整块不出现）。
///
/// 用 [SpbEnv.isMobile] 而非 `defaultTargetPlatform`：与
/// `createWeChatMiniProgramLauncher()` 同一条取向——本仓库的纯逻辑层统一用
/// `dart:io` 判平台，桌面端即使误装配也不会去碰相机插件。
QrScanner createQrScanner() {
  if (!SpbEnv.isMobile) {
    return const NoopQrScanner('桌面端不支持相机扫码（走登录码/反向码那条路）');
  }
  return const MobileQrScanner();
}

/// `mobile_scanner` 支撑的扫码能力：把「打开相机」变成一次整屏页面。
class MobileQrScanner implements QrScanner {
  const MobileQrScanner();

  // 构造它的前提就是 `SpbEnv.isMobile`（见 [createQrScanner]）。
  @override
  bool get isSupported => true;

  @override
  String? get problem => null;

  /// 打开相机页并等待结果。
  ///
  /// 用 `Navigator.push` 而不是 GoRouter 路由：相机页是**一次性插入**的整屏
  /// 动作，不进任何标签栈（与 `/qr-login` 确认页同一条理由，见 `router.dart`
  /// 该路由的注释）。仓库里同类插入动作已有先例（`showModalBottomSheet`）。
  @override
  Future<String?> scan(BuildContext context) {
    return Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const QrScannerPage()));
  }
}

/// 整屏相机扫码页：扫到一枚二维码就关闭自己，把原始文本交回去。
///
/// ## 为什么只认二维码、且 `noDuplicates`
///
/// 登录码只可能是二维码（服务端 `qrcode.Encode` 出的 PNG）。放行所有格式会
/// 让商品条码、外卖单号也触发「扫到了」，然后被上层判成「不是登录码」——
/// 用户白等一次判定的时间。`noDuplicates` 则让同一枚码在取帧间不重复回调，
/// 避免 `_done` 之前连爆几次。
///
/// ## 为什么扫到就 `stop()` 再 `pop`
///
/// 相机是独占资源：页面上还有一帧预览照样亮着，`pop` 的动画期间用户会看到
/// 相机继续取景。先停再走，切换干净；`stop()` 失败不影响结果（文本已经在手）。
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  late final MobileScannerController _controller;

  /// 是否已经交出结果（防同一帧连发多次 `pop`）。
  var _done = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      // 只认二维码：见类注释。
      formats: const [BarcodeFormat.qrCode],
      // 同一枚码不重复回调：`_done` 之外的第二道闸。
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    // 异步释放（插件要停相机并断开预览）；页面已经要离开，无需等待。
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere(
          (v) => v != null && v.trim().isNotEmpty,
          orElse: () => null,
        );
    if (raw == null) return;
    _done = true;
    unawaited(_finish(raw));
  }

  /// 交回结果并关闭自己。
  ///
  /// `stop()` 包在 try 里：相机可能已因系统抢占（来电/别的 App）失效，此时
  /// 停不下来也不该吞掉用户已经扫到的结果。
  Future<void> _finish(String raw) async {
    try {
      await _controller.stop();
    } on Object catch (e) {
      // 停相机失败不影响结果：文本已经拿到，页面马上要离开。
      SpbLog.debug('扫码完成后停止相机失败', {'error': e.toString()});
    }
    if (!mounted) return;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫一扫'),
        leading: IconButton(
          tooltip: '取消',
          icon: const Icon(Icons.close),
          // 取消 = 返回 null：调用方据此安静回到登录页（与「不可用」同义）。
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // 检测异常（解码失败、帧丢失）不打断取景：留一条 debug 痕迹即可，
            // 用户不该因为某一帧烂掉就看到一个错误页。
            onDetectError: (error, stackTrace) {
              SpbLog.debug('扫码取帧异常', {'error': error.toString()});
            },
            errorBuilder: (context, error) => _ScanErrorView(error: error),
          ),
          // 取景提示：二维码在取景框里才认得出来，纯预览没有任何引导。
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: SpbSpacing.xl),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(SpbSpacing.md),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SpbSpacing.lg,
                    vertical: SpbSpacing.sm,
                  ),
                  child: Text(
                    '对准登录二维码',
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
          // 用主题色画一个细取景框，避免整屏黑看起来像卡死。
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 2),
                  borderRadius: BorderRadius.circular(SpbSpacing.md),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 相机不可用时的整屏说明（权限被拒 / 设备没有相机 / 插件报错）。
///
/// ## 为什么不弹一个对话框
///
/// 相机页已经是整屏模态：再叠一层对话框会让用户先关对话框、再关页面，两次
/// 点击才能回到登录页。这里直接就在页面里给出原因和「返回」，一步。
class _ScanErrorView extends StatelessWidget {
  const _ScanErrorView({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography, color: Colors.white, size: 48),
              const SizedBox(height: SpbSpacing.md),
              Text(
                denied ? '相机权限被拒绝' : '相机不可用',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text(
                denied
                    ? '请在系统设置里给「Super PartyB」打开相机权限，然后回到登录页重试。'
                    : '这台设备没有可用的相机，请改用「微信一键登录」或登录码。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: SpbSpacing.lg),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

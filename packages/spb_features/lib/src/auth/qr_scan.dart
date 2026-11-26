import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// 一次「扫码登录」尝试的结果。
///
/// ## 为什么是密封类而不是 `String?`
///
/// 三种失败的意义完全不同，调用方给的文案也不同：用户主动取消（**不该**弹
/// 任何提示）、相机起不来（要说「检查相机权限」）、扫到别人的码（要说
/// 「这不是登录码」）。压成一个可空字符串就没有地方区分它们——写
/// `if (text != null)` 的那种实现只能二选一，要么把取消也报成错误，要么把
/// 扫错码静默吞掉。密封类让调用方在编译期穷举，漏一种分支会直接编译失败。
sealed class QrScanOutcome {
  const QrScanOutcome();
}

/// 扫到了本应用的登录码，[scene] 可以交给路由层去确认。
final class QrScanScene extends QrScanOutcome {
  const QrScanScene(this.scene);

  final String scene;
}

/// 用户取消，或宿主没有相机能力（`onScanQr` 为 null）。
///
/// **不是错误**：登录页与设置页都应当安静地回到原样，不弹提示。
final class QrScanCancelled extends QrScanOutcome {
  const QrScanCancelled();
}

/// 相机打不开（权限被拒 / 硬件异常 / 插件报错）。
final class QrScanCameraFailed extends QrScanOutcome {
  const QrScanCameraFailed();
}

/// 扫到的是本应用之外的二维码（付款码、别的小程序码、随手贴的文字）。
final class QrScanForeignCode extends QrScanOutcome {
  const QrScanForeignCode();
}

/// 三种失败/取消结果的用户文案。
///
/// 集中在这里而不是各页面各写一份：登录页与设置页都会展示同一件事，
/// 两处各写一份的话，改文案时只会改到一处——用户就会在同一个功能上
/// 看到两种说法（并因此以为那是两个不同的毛病）。
String qrScanOutcomeMessage(QrScanOutcome outcome) => switch (outcome) {
  QrScanScene() => '',
  QrScanCancelled() => '',
  QrScanCameraFailed() => '没能打开相机，请检查系统里的相机权限后重试',
  QrScanForeignCode() => '这不是 PartyB 的登录码（扫到的是别的二维码）',
};

/// 打开相机扫一次，并把扫到的文本解释成「登录意图」。
///
/// ## 为什么解释在这里，而不是相机实现里
///
/// 相机（`spb_platform` 的 `QrScanner`）只知道「文本」，不知道什么是登录码
/// ——那是认证域的知识，住在 `spb_api` 的 [QrLoginUri]。把它留在唯一的一处，
/// 登录页与设置页就不会对同一串文本给出不同判断（那种分歧只会在真机上
/// 暴露成「设置页能扫、登录页扫不了」）。
///
/// [scan] 为 null（宿主没注入相机）时返回 [QrScanCancelled]：调用方据此不渲染
/// 入口，`onScanQr` 缺失时也不会有一条「点了没反应」的路径。
///
/// 相机抛异常一律折叠成 [QrScanCameraFailed]：插件抛的是
/// `PlatformException` / `MobileScannerException`，页面无从分辨，用户能做的
/// 动作只有「去系统设置看权限」。
Future<QrScanOutcome> scanQrLoginCode(Future<String?> Function()? scan) async {
  if (scan == null) return const QrScanCancelled();

  String? text;
  try {
    text = await scan();
  } on Object catch (e) {
    // 相机打不开是预期内结果（权限被拒/别的 App 占着相机），留痕即可。
    SpbLog.warn('打开相机扫码时异常', {'error': e.toString()});
    return const QrScanCameraFailed();
  }

  // null = 用户在相机页点了取消，或相机不可用（空实现）。
  if (text == null || text.trim().isEmpty) return const QrScanCancelled();

  final scene = QrLoginUri.parseScannedText(text);
  if (scene == null) return const QrScanForeignCode();
  return QrScanScene(scene);
}

/// 生物识别门禁的契约（issue #94）。
///
/// ## 它解决的是什么问题
///
/// 「下次还要走微信」在移动端有两层原因：**登录**（第一次 / 换设备，必须由 IdP
/// 认账）与**日常进入**（只需证明这台手机的持有者还是同一个人）。后者不需要
/// 再出现在 SSO 页——refresh token 已经在 Keychain / Keystore 里，缺的只是一道
/// 「拿到解锁手机的人不该直接看到内容」的门禁。
///
/// ## 分层：本文件只有契约，插件实现在 App
///
/// 与 [WeChatMiniProgramLauncher] 同一取舍：本包**不** import `local_auth`，
/// 否则桌面端构建也会把移动端插件拖进依赖树（`spb_platform/pubspec.yaml`
/// 里那段教训的同一原因）。真实实现在 `apps/spb_mobile/lib/biometric_gate.dart`，
/// 桌面端注入 [UnsupportedBiometricGate]——桌面没有「应用层门禁」的语义
/// （系统锁屏 + 窗口在前台），硬塞一个假的生物识别提示只会变成摆设。
///
/// ## 这是**应用层自锁**，不是硬件级绑定
///
/// `local_auth` 只是「弹系统验证框并拿到一个 bool」。token 本身**没有**绑定
/// 生物识别 ACL（`flutter_secure_storage` v9 不暴露
/// `kSecAccessControlBiometryCurrentSet`），因此：
///
/// - 挡住「捡到已解锁手机的人」：有效；
/// - 挡住「越狱 / root 后读应用沙盒」：**无效**。
///
/// 硬件级绑定要自建带生物识别 ACL 的 Keychain / Keystore 条目（iOS
/// `SecAccessControlCreateWithFlags` + `.biometryCurrentSet`，Android
/// `setUserAuthenticationRequired` + `BiometricPrompt`），见 issue #94 的
/// 「可选后续」。
library;

/// 设备上生物识别（或设备凭据）的可用性。
///
/// 分四档而不是 `bool`：设置页要对「没硬件」和「有硬件但没录入」给**不同**
/// 的文案——前者是「这台设备不行」，后者是「去系统设置里录一个指纹就好」，
/// 用同一个「不可用」会把后者说成绝症。
enum BiometricAvailability {
  /// 可用：已录入生物识别，或至少设置了设备凭据（PIN / 图案 / 密码）。
  ///
  /// 「有设备凭据但没有生物识别」也算可用：issue #94 明确允许降级到设备密码
  /// （[BiometricGate.authenticate] 的 `allowDeviceCredential`），否则老设备上
  /// 这个功能等于不存在。
  available,

  /// 有硬件但什么都没录（既无生物识别，也未设 PIN / 密码）。
  noCredentials,

  /// 设备没有生物识别硬件。
  noHardware,

  /// 当前平台不支持（桌面、模拟器、未注册插件的环境）。
  unsupported,
}

/// 一次解锁尝试的结果。
///
/// ## 为什么不用 `bool`
///
/// 五种结果对应五种**不同的下一步**：取消不该报错（用户改主意了）、失败要
/// 允许重试、平台锁定必须强制走完整登录、不可用要引导去系统设置。压成
/// `bool` 后「取消」和「越狱失败」长得一样，界面只能给一句含糊的
/// 「解锁失败」——那正是 #94 要避免的体感。
enum BiometricAuthOutcome {
  /// 通过。
  success,

  /// 验证失败（指纹不匹配等），可以重试。
  failed,

  /// 用户取消，或系统取消（来电、切后台）。
  canceled,

  /// 平台已锁定（连续失败太多）或系统要求先用别的方式解锁。
  ///
  /// 此时**不再**重试生物识别：本地门禁已失去意义，正确做法是强制走完整
  /// 登录（IdP 认账），而不是让用户在锁屏页反复戳指纹。
  lockedOut,

  /// 设备不支持 / 没录入 / 插件不可用。
  unavailable,
}

/// 生物识别门禁。
///
/// 实现方负责把平台异常**归一**成 [BiometricAuthOutcome]——上层（`spb_features`
/// 的锁屏页、`apps/spb_mobile` 的 `AuthStateNotifier`）只认这个词汇表，不认识
/// `LocalAuthExceptionCode` 或 `PlatformException`。
abstract class BiometricGate {
  /// 当前设备的可用性（每次询问，不缓存：用户可能刚去系统设置录了指纹）。
  Future<BiometricAvailability> availability();

  /// 发起一次验证。
  ///
  /// [reason] 会显示在系统弹窗上（iOS 的 `localizedReason`、Android 的
  /// `biometricPrompt` 副标题），必须写清「验证通过后会发生什么」。
  ///
  /// [allowDeviceCredential] 为 true 时允许降级到设备 PIN / 密码；为 false
  /// 时只接受生物识别。
  ///
  /// **不抛异常**：失败一律走返回值。上层是 UI 流程，异常只会变成
  /// 「未捕获异常 + 一个卡住的锁屏页」。
  Future<BiometricAuthOutcome> authenticate({
    required String reason,
    bool allowDeviceCredential = true,
  });
}

/// 不支持生物识别的空实现（桌面端 / 测试）。
///
/// [availability] 返回 [BiometricAvailability.unsupported]，
/// [authenticate] 返回 [BiometricAuthOutcome.unavailable]——**永不通过**。
/// 这一点很重要：空实现若「假装成功」，桌面端就会在依赖被误接线时静默
/// 跳过门禁。
class UnsupportedBiometricGate implements BiometricGate {
  const UnsupportedBiometricGate();

  @override
  Future<BiometricAvailability> availability() async =>
      BiometricAvailability.unsupported;

  @override
  Future<BiometricAuthOutcome> authenticate({
    required String reason,
    bool allowDeviceCredential = true,
  }) async => BiometricAuthOutcome.unavailable;
}

/// 门禁策略（纯数据 + 纯函数，便于无头单测）。
class BiometricLockPolicy {
  const BiometricLockPolicy({
    this.gracePeriod = const Duration(seconds: 30),
    this.allowDeviceCredential = true,
  });

  /// 切到后台多久之后回来需要重新解锁。
  ///
  /// ## 为什么不是「一切后台就锁」
  ///
  /// 移动端的正常操作就会短暂离开应用：看一眼通知、从相册选一张图、跳去
  /// 浏览器复制一段内容再回来。每次都弹 Face ID 会让用户关掉这个功能，
  /// 那还不如没有。30 秒足够覆盖这些动作，又短于「手机被别人拿走」的时间尺度。
  ///
  /// 真机验证前这是**估算值**，不是实测结论。
  final Duration gracePeriod;

  /// 是否允许降级到设备 PIN / 密码。
  final bool allowDeviceCredential;

  /// 「生物识别解锁」偏好的默认值。
  ///
  /// ## 为什么默认关
  ///
  /// 这是**用户同意**类功能：开启意味着每次冷启动都要过一道系统验证框。默认
  /// 打开会让「只是想看看消息」的用户觉得被拦，而他们从没要求过这件事；更
  /// 糟的是门禁失败时的兜底是「重新登录」，对没准备的用户等于被踢出去。
  ///
  /// 想改默认值只需改这一处（设置页与启动逻辑都读它）。
  static const enabledByDefault = false;

  /// 偏好存储的键（`PreferencesStore`，明文键值；这里只有「开关是否打开」，
  /// 不含任何凭证）。
  static const preferenceKey = 'biometric_lock_enabled';
}

/// 回到前台时是否需要重新上锁（纯函数）。
///
/// 判据三条，缺一不可：
///
/// 1. 用户**开着**这个功能（默认关，见
///    [BiometricLockPolicy.enabledByDefault]）；
/// 2. 当前**已登录**——未登录 / 未判定时本来就看不到内容，上锁没有意义，还会
///    把正在进行的 OIDC 回调流程打断；
/// 3. 离开的时长**超过**宽限期。等于宽限期时不算（`>` 而非 `>=`：避免
///    「刚好 30 秒」这种边界在测试里随机翻面）。
///
/// 抽成纯函数是为了能逐条钉住——放进 `AuthStateNotifier` 就只能靠 widget
/// 测试间接观察，而那种测试对「差一秒」这类边界几乎无法断言。
bool shouldLockOnResume({
  required bool enabled,
  required bool authenticated,
  required Duration backgrounded,
  required Duration gracePeriod,
}) {
  if (!enabled) return false;
  if (!authenticated) return false;
  return backgrounded > gracePeriod;
}

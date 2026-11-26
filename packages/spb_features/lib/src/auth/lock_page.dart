import 'dart:async';

import 'package:flutter/material.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_platform/spb_platform.dart';

/// 本机门禁锁屏页（issue #94）。
///
/// ## 它出现在什么时候
///
/// 只有在**已存有凭证**、且用户开着「生物识别解锁」时才出现：冷启动与「切到
/// 后台超过宽限期再回来」两条入口都会走到这里（只挡其中一条等于没挡——把
/// App 切后台再切回来就绕过了）。页面本身不读凭证，凭证也没被清掉；它只负责
/// 「本机验证通过后，把已登录状态还给用户」。
///
/// ## 与登录页的分工
///
/// - 这里**不会**出现扫码 / 邮箱登录：用户早就登录过了，弹登录方式正是本次
///   要消除的体感；
/// - 但必须留一个 [onUseSignIn] 出口。生物识别可能在系统层被锁死（连续失败、
///   录入被删掉、硬件故障），没有这个出口用户就被**永久关在门外**——这是
///   门禁类功能最常见的差评来源。
///
/// ## 页面职责边界
///
/// 与 [LoginPage] 一致：只渲染与回调，**不导航**。解锁成功后跳哪里由路由守卫
/// 决定（`AuthState` 从 locked 变成 authenticated，守卫自己会放行）。
class SessionLockPage extends StatefulWidget {
  const SessionLockPage({
    super.key,
    required this.onUnlock,
    required this.onUseSignIn,
    this.allowDeviceCredential = true,
    this.autoPrompt = true,
  });

  /// 发起一次本机验证（装配层注入 `AuthStateNotifier.unlock`）。
  ///
  /// 返回 [BiometricAuthOutcome]，页面据此决定文案与「还能不能再试」。
  final Future<BiometricAuthOutcome> Function() onUnlock;

  /// 「改用登录」：清掉本机会话并切到未登录。
  ///
  /// 名字用 `onUseSignIn` 而不是 `onSignOut`：用户视角是「我要换个方式进去」，
  /// 不是「我要退出账号」。
  final Future<void> Function() onUseSignIn;

  /// 是否允许降级到设备 PIN / 密码（展示在说明文字里，不改行为——
  /// 行为由装配层传给 `BiometricGate.authenticate`）。
  final bool allowDeviceCredential;

  /// 进页面就自动弹系统验证框。
  ///
  /// 默认 true：用户刚打开 App，最想要的是「立刻进去」。测试可关掉以避免
  /// 首帧就产生一次假的验证调用。
  final bool autoPrompt;

  @override
  State<SessionLockPage> createState() => _SessionLockPageState();
}

class _SessionLockPageState extends State<SessionLockPage> {
  /// 正在等系统验证框返回。
  bool _busy = false;

  /// 上一次的结果（null = 还没试过）。
  BiometricAuthOutcome? _last;

  /// 本次会话里是否已经「用尽」——平台锁定 / 设备不可用时不再给重试按钮，
  /// 只留「改用登录」。反复弹一个注定失败的验证框只会让用户以为应用坏了。
  bool _exhausted = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPrompt) {
      // 首帧之后再弹：initState 里直接调会在路由转场动画期间弹框，部分平台
      // （Android）因此报 `uiUnavailable`。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_attempt());
      });
    }
  }

  Future<void> _attempt() async {
    if (_busy || _exhausted) return;
    setState(() => _busy = true);
    BiometricAuthOutcome outcome;
    try {
      outcome = await widget.onUnlock();
    } catch (e) {
      // onUnlock 契约上不抛（`BiometricGate.authenticate` 已归一成返回值），
      // 但装配层可能抛 I/O 类异常。这里兜住：宁可显示「再试一次」，也不能
      // 让锁屏页抛异常——那会留用户停在一屏红字上，且看不到出口按钮。
      SpbLog.warn('解锁时出现未预期异常', {'error': e.toString()});
      outcome = BiometricAuthOutcome.failed;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _last = outcome;
      // 成功时不置 exhausted：页面即将被守卫换掉，状态无所谓；但保持逻辑单一。
      _exhausted =
          outcome == BiometricAuthOutcome.lockedOut ||
          outcome == BiometricAuthOutcome.unavailable;
    });
  }

  Future<void> _useSignIn() async {
    setState(() => _busy = true);
    try {
      await widget.onUseSignIn();
    } finally {
      // 成功时页面会被守卫换走；失败（清凭证出错）也要把按钮还回去，
      // 否则用户只剩一个永远转圈的按钮。
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 提示文案（null = 不显示提示）。
  ///
  /// 刻意**不**把「用户取消」写成错误：取消是他自己的选择，弹一句红字等于
  /// 在指责用户。
  String? get _hint => switch (_last) {
    null => null,
    BiometricAuthOutcome.success => null,
    BiometricAuthOutcome.canceled => '需要验证身份后才能继续',
    BiometricAuthOutcome.failed => '验证未通过，可以再试一次',
    BiometricAuthOutcome.lockedOut => '本机验证已被系统锁定，请重新登录',
    BiometricAuthOutcome.unavailable => '当前设备无法完成本机验证，请重新登录',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = _hint;
    final canRetry = !_exhausted;

    return Scaffold(
      key: const ValueKey('session-lock'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(SpbSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, size: 56),
                  const SizedBox(height: SpbSpacing.lg),
                  Text(
                    '已锁定',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: SpbSpacing.sm),
                  Text(
                    widget.allowDeviceCredential
                        ? '用指纹 / Face ID（或设备密码）解锁以继续'
                        : '用指纹 / Face ID 解锁以继续',
                    key: const ValueKey('session-lock-subtitle'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (hint != null) ...[
                    const SizedBox(height: SpbSpacing.md),
                    Text(
                      hint,
                      key: const ValueKey('session-lock-hint'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _exhausted
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: SpbSpacing.xl),
                  if (canRetry)
                    FilledButton(
                      key: const ValueKey('session-lock-unlock'),
                      onPressed: _busy ? null : _attempt,
                      child: _busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('解锁'),
                    )
                  else
                    FilledButton(
                      key: const ValueKey('session-lock-signin-primary'),
                      onPressed: _busy ? null : _useSignIn,
                      child: const Text('重新登录'),
                    ),
                  const SizedBox(height: SpbSpacing.sm),
                  // 「改用登录」在还能重试时是次要出口，用尽的场景下升为主按钮
                  // （上面那条）。两种情况都保留可点，用户不会被卡住。
                  if (canRetry)
                    TextButton(
                      key: const ValueKey('session-lock-signin'),
                      onPressed: _busy ? null : _useSignIn,
                      child: const Text('改用登录'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

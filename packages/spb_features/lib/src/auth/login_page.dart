import 'package:flutter/material.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';

import 'auth_state.dart';

/// 登录页。
///
/// ## 认证形态（实测依据：`docs/oidc-verification.md`）
///
/// 生产链路由 **api-gateway 托管 OIDC**，且 IdP 对 `redirect_uri` 做
/// **精确匹配**——只认预注册的三个网关回调，自定义 scheme 与 loopback 都被
/// 拒绝（实测 400 `invalid_request`）。因此本页**不自己拼授权 URL、不自己换
/// token**，只做一件事：让用户去网关的 `/auth/oidc/authorize` 完成登录。
///
/// 本页刻意**不依赖 `url_launcher` 等平台插件**：打开浏览器的动作由
/// [onSignIn] 注入（app 装配层决定用系统浏览器 / 内嵌 webview / 别的机制）。
/// 这样本页可以在无插件的 widget test 里完整验证，也避免 `spb_features`
/// 为一个按钮引入平台依赖。
///
/// ## 页面职责边界
///
/// - **只负责**渲染与回调：按钮、加载态、错误展示；
/// - **不负责**导航：登录成功后跳哪里由路由守卫（`redirect`）决定，
///   因为「当前在哪个页面」是路由层的知识，页面自己跳会和守卫打架。
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.onSignIn,
    this.state = const AuthState(),
    this.title = '登录 Super PartyB',
    this.subtitle = '使用统一身份认证中心（SSO）登录',
  });

  /// 发起登录。返回 null 表示已成功发起（等待外部回调），
  /// 返回字符串表示失败原因（直接显示给用户）。
  ///
  /// 用返回值而非抛异常：失败原因（未配置 client_id、无法打开浏览器、
  /// 用户取消）都是**预期内的**用户可见信息，不该走异常通道。
  final Future<String?> Function() onSignIn;

  /// 当前认证状态（错误消息从这里读）。
  final AuthState state;

  final String title;
  final String subtitle;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  /// 是否正在发起登录（防重复点击 + 显示加载态）。
  bool _busy = false;

  /// 本页自己捕获的失败原因（优先于 `widget.state.message`）。
  String? _localError;

  @override
  void didUpdateWidget(LoginPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部状态变化（如路由守卫把错误塞进 AuthState）时清掉本地错误，
    // 避免显示的是上一次点击留下的陈旧消息。
    if (oldWidget.state.message != widget.state.message) _localError = null;
  }

  Future<void> _handleSignIn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _localError = null;
    });

    String? error;
    try {
      error = await widget.onSignIn();
    } catch (e) {
      // onSignIn 的实现理论上返回错误串，但插件调用可能抛（如平台通道异常）。
      // 兜住并转成可展示文案，避免登录页白屏。
      SpbLog.warn('发起 SSO 登录时异常', {'error': e.toString()});
      error = '无法发起登录：$e';
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _localError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 本地错误优先：它是用户刚触发的那次操作的结果。
    final error = _localError ?? widget.state.message;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: SpbSpacing.pagePadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: SpbSpacing.xxxl,
                  color: scheme.primary,
                ),
                const SizedBox(height: SpbSpacing.lg),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: textTheme.headlineSmall,
                ),
                const SizedBox(height: SpbSpacing.sm),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: SpbSpacing.xl),
                if (error != null) ...[
                  _ErrorBanner(message: error),
                  const SizedBox(height: SpbSpacing.lg),
                ],
                FilledButton.icon(
                  key: const ValueKey('login-sso-button'),
                  // 加载中禁用，避免重复发起授权（会产生多个 state）。
                  onPressed: _busy ? null : _handleSignIn,
                  icon: _busy
                      ? const SizedBox(
                          width: SpbSpacing.lg,
                          height: SpbSpacing.lg,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(_busy ? '正在跳转…' : '使用 SSO 登录'),
                ),
                const SizedBox(height: SpbSpacing.md),
                Text(
                  '登录将在浏览器中完成，完成后返回本应用。',
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 错误提示条。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('login-error'),
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

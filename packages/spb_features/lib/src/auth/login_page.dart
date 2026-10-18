import 'package:flutter/material.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';

import 'auth_state.dart';

/// 登录页。
///
/// ## 认证形态：RFC 8252 §7.3 loopback（桌面端）
///
/// 桌面端用**系统浏览器 + 本地回环回调**完成授权码流程：
///
/// 1. 客户端 bind `127.0.0.1:<随机端口>`，拿 `http://127.0.0.1:<port>/callback`
///    作为 `redirect_uri`（直连 IdP，带 PKCE）；
/// 2. 系统浏览器完成登录，IdP 302 回本地端口；
/// 3. 客户端取出 code 并换 token，落盘后自动进入应用。
///
/// 这是 RFC 8252 §7.3 为桌面操作系统指定的重定向方式，也是 RFC 8252 §8.12
/// 要求的「必须用外部用户代理（系统浏览器）而非内嵌 webview」的体现。
///
/// 本页刻意**不依赖任何平台插件**：登录动作完全由 [onSignIn] 注入
/// （app 装配层用 `loopbackSignIn`）。这样本页可以在无插件的 widget test 里
/// 完整验证，也避免 `spb_features` 为登录引入平台依赖。
///
/// ## 粘贴导入：降级路径
///
/// [onImportSession] 是 loopback 流程不可用时的兑底（例如 IdP 尚未注册
/// public client、或安全存储不可用）。两者互斥且同一意图（「让我进去」）。
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
    this.onImportSession,
    this.title = '登录 Super PartyB',
    this.subtitle = '使用统一身份认证中心（SSO）登录',
  });

  /// 发起登录。返回 null 表示已成功发起（等待外部回调），
  /// 返回字符串表示失败原因（直接显示给用户）。
  ///
  /// 用返回值而非抛异常：失败原因（未配置 client_id、无法打开浏览器、
  /// 用户取消）都是**预期内的**用户可见信息，不该走异常通道。
  final Future<String?> Function() onSignIn;

  /// 粘贴导入已有会话。返回 null 成功 / 字符串失败原因（与 [onSignIn] 同语义）。
  ///
  /// ## 为什么需要它（桌面端登录闭环的唯一缺口）
  ///
  /// SSO 在**系统浏览器**里完成，会话 Cookie 落在浏览器中，而 Flutter 进程
  /// 读不到浏览器 Cookie（Linux 无主流 webview 插件，见
  /// `docs/oidc-verification.md` §2.3）。于是「用户把浏览器里的会话交到客户端」
  /// 必须有一个入口——就是这里。
  ///
  /// ## 为什么不做成独立页面
  ///
  /// 它是**登录页的替代路径**，不是新功能：用户要么点 SSO，要么粘贴会话，
  /// 二者互斥且同一意图（「让我进去」）。放同一个页面里，用户失败一次后能立刻
  /// 看到另一条路；独立页面则要求用户先知道它存在。
  ///
  /// 为 null 时不展示该区域（移动端已有深链回调，不需要粘贴）。
  final Future<String?> Function(String raw)? onImportSession;

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

  /// 「粘贴导入」区域是否展开（默认收起，不喧宾夺主）。
  bool _importExpanded = false;

  /// 导入用的文本控制器（随区域展开创建，收起时释放）。
  final TextEditingController _importController = TextEditingController();

  /// 是否正在导入（防重复提交）。
  bool _importing = false;

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

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

  /// 粘贴导入会话。
  ///
  /// ## 为什么空输入不发请求
  ///
  /// 点按钮时输入框为空，说明用户还没粘贴——给出「请先粘贴」比发一次必然失败
  /// 的请求更快、更省事。
  Future<void> _handleImportSession() async {
    final handler = widget.onImportSession;
    if (handler == null || _importing) return;

    final raw = _importController.text.trim();
    if (raw.isEmpty) {
      setState(() => _localError = '请先粘贴会话内容');
      return;
    }

    setState(() {
      _importing = true;
      _localError = null;
    });

    String? error;
    try {
      error = await handler(raw);
    } catch (e) {
      SpbLog.warn('导入会话时异常', {'error': e.toString()});
      error = '导入失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _importing = false;
      _localError = error;
      // 成功后清空输入框：凭证留在 widget 的 TextEditingController 里没有
      // 任何用处，而它的内容就是凭证本身。
      if (error == null) _importController.clear();
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
        child: SingleChildScrollView(
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
                    ErrorBanner(
                      key: const ValueKey('login-error'),
                      message: error,
                    ),
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
                    label: Text(_busy ? '正在登录…' : '使用 SSO 登录'),
                  ),
                  const SizedBox(height: SpbSpacing.md),
                  Text(
                    '登录将在系统浏览器中完成，'
                    '完成后自动返回本应用（本地回环回调）。',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (widget.onImportSession != null) ...[
                    const SizedBox(height: SpbSpacing.lg),
                    _buildImportSection(context),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 粘贴导入区域。
  ///
  /// 默认收起：它是**备选**路径，展开着会让登录页看起来像有两条对等的入口，
  /// 而绝大多数用户应该走 SSO。
  Widget _buildImportSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          key: const ValueKey('login-import-session'),
          onPressed: () => setState(() => _importExpanded = !_importExpanded),
          icon: Icon(_importExpanded ? Icons.expand_less : Icons.expand_more),
          label: Text(_importExpanded ? '收起' : '已有会话？粘贴导入'),
        ),
        if (_importExpanded) ...[
          const SizedBox(height: SpbSpacing.sm),
          Text(
            '在浏览器开发者工具的「应用 → Cookie」或「网络 → 请求头」里复制 '
            'id_token / access_token，粘贴到这里。',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: SpbSpacing.sm),
          TextField(
            key: const ValueKey('login-import-field'),
            controller: _importController,
            maxLines: 4,
            minLines: 2,
            // 凭证不该被输入法记录或拼写检查（会进系统词典/云同步）。
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'id_token=eyJ…; refresh_token=…',
            ),
          ),
          const SizedBox(height: SpbSpacing.sm),
          FilledButton.tonal(
            key: const ValueKey('login-import-confirm'),
            onPressed: _importing ? null : _handleImportSession,
            child: Text(_importing ? '正在导入…' : '导入会话'),
          ),
        ],
      ],
    );
  }
}

/// 错误提示条。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:spb_api/spb_api.dart';
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
    this.onWeChatSignIn,
    this.onEmailSignIn,
    this.onHandoffSignIn,
    this.title = '登录 Super PartyB',
    this.subtitle = '使用统一身份认证中心（SSO）登录',
    this.miniProgramName = '成蹊',
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

  /// 微信一键登录（App 内唤起小程序确认）。
  ///
  /// 返回 null 表示成功，字符串是失败原因（与 [onSignIn] 同语义）。
  ///
  /// ## 为什么单独一条入口
  ///
  /// 手机上 SSO 至少 3 次跳转；而扫码登录在**同机**根本无法完成（用户只有
  /// 这一台手机，扫不了自己屏幕上的码）。这条路径是移动端唯一能「一步到位」
  /// 的登录方式：唤起小程序 → 在微信里确认 → 回到 App 已登录。
  ///
  /// ## 短码回退
  ///
  /// 唤起小程序的两条通道都可能**运行期**不可用（OpenSDK 未配置 / 个人主体
  /// 小程序拿不到 URL Scheme）。此时编排层会改发一个 6 位码，通过 [onShortCode]
  /// 回调交给本页展示：用户自己打开小程序输入它，登录照样完成。
  ///
  /// 本页只负责**把码显示清楚**（大字号 + 分组 + 倒计时），是否走这条路、
  /// 何时结束，全在编排层。传 null 表示不支持回退（保持旧的失败行为）。
  ///
  /// 为 null 时不展示（桌面端没有微信小程序场景）。
  final Future<String?> Function(
    void Function(MiniProgramShortCode code)? onShortCode,
  )?
  onWeChatSignIn;

  /// 反向登录码：在已登录的小程序里出码 → 抄到本设备 → 直接登录。
  ///
  /// 返回 null 表示成功（已登录），字符串是失败原因（与 [onSignIn] 同语义）。
  ///
  /// ## 与 [onWeChatSignIn] 的方向相反
  ///
  /// [onWeChatSignIn] 是「本设备出码、手机小程序确认」；这里是「手机小程序出码、
  /// 本设备输码」。后者不依赖任何微信「打开能力」（URL Scheme 需要主体资质），
  /// 也不依赖 IdP 的 public client 注册或邮件通道——是**桌面端**唯一一条
  /// 不靠运维配置就能走通的无摩擦路径。
  ///
  /// 代价：码是「持有即授权的凭据」（8 位、2 分钟、一次性），所以页面必须
  /// 明确写出「别把码发给别人」，并只让用户自己抄。
  ///
  /// 为 null 时不展示。
  final Future<String?> Function(String code)? onHandoffSignIn;

  /// 邮箱 magic link 登录：输邮箱 → 收信 → 点链接确认 → 自动登录。
  ///
  /// 第二个参数 `onSent` 由本页提供，处理函数在**邮件受理成功**后调用它，
  /// 页面据此把按钮文案从「正在发送…」切到「已发送，请在邮件中确认…」。
  /// 没有它，用户在两三秒后看到按钮还在转圈，会以为卡住而重复点击。
  ///
  /// 返回 null 表示成功（已登录），字符串是失败原因（与 [onSignIn] 同语义）。
  ///
  /// ## 为什么这条路径值得单列一个入口
  ///
  /// SSO 要求用户在浏览器里完成一整套跳转；微信一键要求装微信且受开放平台
  /// 审核约束。magic link 只要一个能收信的邮箱——它是**唯一**对「没装微信、
  /// 又嫌 SSO 跳转麻烦」的用户成立的路径。
  ///
  /// ## 为什么文案不能说「邮件已发送」
  ///
  /// 服务端对不存在的邮箱也返回成功（防枚举），客户端拿不到「是否存在」的
  /// 信息。写成「如果该邮箱已注册，你会收到…」才对得上实际行为。
  ///
  /// 为 null 时不展示（例如未配置 IdP 的环境）。
  final Future<String?> Function(String email, void Function() onSent)?
  onEmailSignIn;

  /// 当前认证状态（错误消息从这里读）。
  final AuthState state;

  /// 微信小程序的名称（短码文案里要写出来）。
  ///
  /// 必须写出名字：短码这条路上 App **唤不起**小程序，用户得自己去微信里找它。
  /// 只说「打开小程序」等于把「哪个小程序、在哪找」全留给用户猜，而搜索框里
  /// 猜错名字是这条路径最常见的断点。
  final String miniProgramName;

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

  /// 是否正在等待微信确认（唤起小程序后轮询期间）。
  bool _wechatBusy = false;

  /// 短码回退时拿到的 6 位码（null = 没走短码这条路）。
  MiniProgramShortCode? _shortCode;

  /// 短码失效的墙钟时刻。
  ///
  /// 只用「每秒自减」的话，应用被切到后台时 Timer 会停走，回到前台显示的
  /// 剩余时间是错的（比真实值大）；只读墙钟的话，测试里推进的假时钟对不上。
  /// 所以两者取**较小值**：自减负责帧内平滑，墙钟负责后台/卡顿后的纠偏。
  DateTime? _shortCodeDeadline;

  /// 按 Timer 跳动自减的剩余秒数（见 [_shortCodeDeadline]）。
  int _shortCodeSecondsLeft = 0;

  /// 短码倒计时的秒表（只在展示短码时跑，归零或流程结束时立刻停）。
  Timer? _shortCodeTicker;

  /// 是否正在等待邮件确认（已发信 → 轮询期间）。
  bool _emailBusy = false;

  /// 邮件是否已受理（决定按钮文案：正在发送 / 已发送）。
  bool _emailSent = false;

  /// 邮箱输入控制器。
  final TextEditingController _emailController = TextEditingController();

  /// 反向登录码输入控制器。
  final TextEditingController _handoffController = TextEditingController();

  /// 是否正在兑换反向登录码（防重复提交）。
  bool _handoffBusy = false;

  @override
  void dispose() {
    _shortCodeTicker?.cancel();
    _importController.dispose();
    _emailController.dispose();
    _handoffController.dispose();
    super.dispose();
  }

  /// 接住编排层给出的短码并开始倒计时。
  ///
  /// 倒计时不是装饰：码 5 分钟就失效，用户看不到剩余时间就会在失败后反复抄
  /// 同一个过期码。`setState` 每秒一次，只在码还在显示时跑。
  void _showShortCode(MiniProgramShortCode code) {
    if (!mounted) return;
    _shortCodeTicker?.cancel();
    setState(() {
      _shortCode = code;
      _shortCodeDeadline = DateTime.now().add(code.ttl);
      _shortCodeSecondsLeft = code.ttl.inSeconds;
    });
    _shortCodeTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      // 归零就停表：否则登录页会带着一个空转的 Timer 一直到流程结束，
      // 测试里的 pumpAndSettle 也会因为「永远有下一帧」而超时。
      setState(() {
        if (_shortCodeSecondsLeft > 0) _shortCodeSecondsLeft--;
      });
      if (_shortCodeRemaining() <= Duration.zero) {
        t.cancel();
        _shortCodeTicker = null;
      }
    });
  }

  Duration _shortCodeRemaining() {
    final deadline = _shortCodeDeadline;
    if (deadline == null) return Duration.zero;
    final wall = deadline.difference(DateTime.now());
    // 向上取整：刚拿到码时真实剩余是 299.98s，`inSeconds` 会截成 299，
    // 用户第一眼看到「04:59」会以为已经过了一秒。
    final wallSeconds = wall.isNegative
        ? 0
        : (wall.inMilliseconds + 999) ~/ 1000;
    final seconds = _shortCodeSecondsLeft < wallSeconds
        ? _shortCodeSecondsLeft
        : wallSeconds;
    return Duration(seconds: seconds);
  }

  void _clearShortCode() {
    _shortCodeTicker?.cancel();
    _shortCodeTicker = null;
    if (_shortCode != null) {
      setState(() {
        _shortCode = null;
        _shortCodeDeadline = null;
        _shortCodeSecondsLeft = 0;
      });
    }
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

  /// 微信一键登录。
  ///
  /// 与 [_handleSignIn] 的差别：这条路会**一直等到**微信里确认完成（轮询），
  /// 所以按钮文案要说明「在微信里确认」，否则用户会以为卡住了。
  Future<void> _handleWeChatSignIn() async {
    final handler = widget.onWeChatSignIn;
    if (handler == null || _wechatBusy) return;

    setState(() {
      _wechatBusy = true;
      _localError = null;
    });

    String? error;
    try {
      error = await handler(_showShortCode);
    } catch (e) {
      SpbLog.warn('微信登录时异常', {'error': e.toString()});
      error = '微信登录失败：$e';
    }

    if (!mounted) return;
    // 流程结束（成功或失败）后短码已无意义：留在屏幕上只会让人继续抄一个
    // 已经失效/已用掉的码。
    _clearShortCode();
    setState(() {
      _wechatBusy = false;
      _localError = error;
    });
  }

  /// 邮箱 magic link 登录。
  ///
  /// 与另外两条入口的差别：它**当场不会登录成功**——要等用户去收信并点
  /// 「确认登录」。所以按钮在等待期间保持加载态，并说明「请查收邮件」。
  Future<void> _handleEmailSignIn() async {
    final handler = widget.onEmailSignIn;
    if (handler == null || _emailBusy) return;

    final email = _emailController.text.trim();
    if (email.isEmpty) {
      // 空输入直接提示，省掉一次必然失败的请求。
      setState(() => _localError = '请先输入邮箱地址');
      return;
    }

    setState(() {
      _emailBusy = true;
      _emailSent = false;
      _localError = null;
    });

    String? error;
    try {
      error = await handler(email, () {
        // 邮件已受理：切文案。页面可能已被销毁（用户返回上一页），故判 mounted。
        if (mounted) setState(() => _emailSent = true);
      });
    } catch (e) {
      SpbLog.warn('邮箱登录时异常', {'error': e.toString()});
      error = '邮箱登录失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _emailBusy = false;
      _emailSent = false;
      _localError = error;
    });
  }

  /// 反向登录码：把手机上小程序里显示的 8 位码提交给 IdP。
  ///
  /// 与邮箱入口一样**当场**就能出结果（成功直接进应用，失败给可操作文案），
  /// 所以不需要「等待中」的中间态。
  Future<void> _handleHandoffSignIn() async {
    final handler = widget.onHandoffSignIn;
    if (handler == null || _handoffBusy) return;

    final code = _handoffController.text.trim();
    if (code.isEmpty) {
      setState(() => _localError = '请先输入登录码');
      return;
    }

    setState(() {
      _handoffBusy = true;
      _localError = null;
    });

    String? error;
    try {
      error = await handler(code);
    } catch (e) {
      SpbLog.warn('反向登录码登录时异常', {'error': e.toString()});
      error = '登录码登录失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _handoffBusy = false;
      _localError = error;
      // 成功后清空输入框：码就是凭据，留在控制器里没有任何用处。
      if (error == null) _handoffController.clear();
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
                  // 品牌标志（成蹊 / Super PartyB）。
                  //
                  // 此前是 `Icons.shield_outlined` 占位——盾牌与产品无关，且
                  // 与「统一身份认证」的暗示重复（下面的副标题已说明）。换成
                  // 真正的品牌标志后，用户第一眼就知道自己装的是哪个应用。
                  //
                  // 尺寸用 xxxl（48）：登录页首屏不宜过大，且它下面紧跟标题，
                  // 再大就会把 SSO 按钮挤出小屏（320dp 高度）。
                  const Center(
                    child: SpbLogo(
                      key: ValueKey('login-logo'),
                      size: SpbSpacing.xxxl,
                    ),
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
                  if (widget.onWeChatSignIn != null) ...[
                    if (_shortCode != null) ...[
                      _ShortCodeCard(
                        key: const ValueKey('login-short-code'),
                        code: _shortCode!,
                        remaining: _shortCodeRemaining(),
                        miniProgramName: widget.miniProgramName,
                      ),
                      const SizedBox(height: SpbSpacing.lg),
                    ],
                    FilledButton.icon(
                      key: const ValueKey('login-wechat-button'),
                      // 两个入口互斥：任一进行中就都禁用，避免并发发起两套
                      // 登录流程（state/PKCE 会互相覆盖）。
                      onPressed: _busy || _wechatBusy || _emailBusy
                          ? null
                          : _handleWeChatSignIn,
                      icon: _wechatBusy
                          ? const SizedBox(
                              width: SpbSpacing.lg,
                              height: SpbSpacing.lg,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chat_bubble_outline),
                      label: Text(_wechatBusy ? '请在微信中确认…' : '微信一键登录'),
                    ),
                    const SizedBox(height: SpbSpacing.sm),
                    Text(
                      _shortCode == null
                          ? '将打开微信小程序，确认后自动返回本应用。'
                          : '打开微信 → 搜索或「发现 → 小程序」进入「${widget.miniProgramName}」→「我的 → 输入登录码」，填入上面的码。',
                      textAlign: TextAlign.center,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: SpbSpacing.lg),
                  ],
                  FilledButton.icon(
                    key: const ValueKey('login-sso-button'),
                    // 加载中禁用，避免重复发起授权（会产生多个 state）。
                    onPressed: _busy || _wechatBusy || _emailBusy
                        ? null
                        : _handleSignIn,
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
                    // 提一句浏览器页里的免密入口：那是用户真正打开的那一页，
                    // 只在 App 里写「用邮件登录」的话，从这里进 SSO 的人不会知道
                    // 浏览器页上还有这条路。
                    '登录将在系统浏览器中完成，完成后自动返回本应用。'
                    '浏览器页也可选「用邮件登录」免密进入。',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (widget.onEmailSignIn != null) ...[
                    const SizedBox(height: SpbSpacing.lg),
                    _buildEmailSection(context),
                  ],
                  if (widget.onHandoffSignIn != null) ...[
                    const SizedBox(height: SpbSpacing.lg),
                    _buildHandoffSection(context),
                  ],
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

  /// 反向登录码区域（手机小程序出码 → 本设备输码）。
  ///
  /// 与邮箱区域一样**始终可见**：它是一条对等的登录路径，不是补救措施。
  /// 收起会让「手机上没有微信/桌面没有 public client」的用户永远发现不了它。
  Widget _buildHandoffSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final locked = _busy || _wechatBusy || _emailBusy || _handoffBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.sm),
              child: Text(
                '或用手机小程序登录',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: SpbSpacing.md),
        TextField(
          key: const ValueKey('login-handoff-field'),
          controller: _handoffController,
          enabled: !locked,
          // 码是大写字母+数字：默认大写键盘，且关掉自动纠正/建议
          // （输入法把 `AB2C` 改成 `AB2c` 之类会让用户看不出哪里错了）。
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 9, // 8 位 + 一个分隔符
          decoration: InputDecoration(
            labelText: '登录码',
            hintText: 'AB2C-3D4E',
            counterText: '',
            helperText: '在手机微信里打开「${widget.miniProgramName}」→ 我的 → 在别的设备上登录',
            helperMaxLines: 2,
          ),
          // 服务端会归一化（去横线/小写），这里只做长度与可读性提示。
          // 等宽 + 字距 2：8 位码分组更易读。走 `SpbType.mono` 是为了把
          // `monoFallback`（CJK 兜底）一并带上（§6.81）。
          style: SpbType.mono(
            textTheme,
            base: textTheme.bodyLarge,
          )?.copyWith(letterSpacing: 2),
          onSubmitted: (_) => _handleHandoffSignIn(),
        ),
        const SizedBox(height: SpbSpacing.sm),
        FilledButton.tonal(
          key: const ValueKey('login-handoff-button'),
          onPressed: locked ? null : _handleHandoffSignIn,
          child: _handoffBusy
              ? const SizedBox(
                  width: SpbSpacing.lg,
                  height: SpbSpacing.lg,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('用登录码登录'),
        ),
        const SizedBox(height: SpbSpacing.sm),
        Text(
          // 码是「持有即授权」的一次性凭据：不写清楚，用户会截图发微信求助，
          // 而拿到截图的人就能登录他的账号。
          '登录码 2 分钟内有效、只能用一次。请勿把码发给任何人。',
          textAlign: TextAlign.center,
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// 邮箱 magic link 登录区域。
  ///
  /// 输入框与按钮始终可见（不像粘贴导入那样收起）：它是一条**对等**的登录
  /// 路径，不是补救措施。收起会让不知道它存在的用户永远用不上。
  Widget _buildEmailSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final locked = _busy || _wechatBusy || _emailBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.sm),
              child: Text(
                '或',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: SpbSpacing.md),
        TextField(
          key: const ValueKey('login-email-field'),
          controller: _emailController,
          enabled: !locked,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _handleEmailSignIn(),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: '邮箱地址',
            hintText: 'you@example.com',
          ),
        ),
        const SizedBox(height: SpbSpacing.sm),
        FilledButton.tonal(
          key: const ValueKey('login-email-button'),
          onPressed: locked ? null : _handleEmailSignIn,
          child: Text(
            _emailBusy ? (_emailSent ? '已发送，请在邮件中确认…' : '正在发送…') : '用邮件登录',
          ),
        ),
        const SizedBox(height: SpbSpacing.sm),
        Text(
          _emailBusy && _emailSent
              ? '如果该邮箱已注册，你会收到一封登录邮件。点开链接并确认后，'
                    '本应用会自动完成登录。'
              : '我们会向该邮箱发送一次性登录链接，无需密码。',
          textAlign: TextAlign.center,
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
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

/// 6 位短码展示卡（微信一键登录的兜底通道）。
///
/// ## 为什么要这么大
///
/// 用户要**手抄**这 6 个字符到另一个界面，抄错一位就得到「码无效」。所以：
/// - 字号大、字距宽，分段显示（`A3F-9K2`，服务端给的 displayCode 就是这个形态）；
/// - 等宽字体：`I`/`1`、`O`/`0` 这类混淆在比例字体里更容易看错（字符集本身
///   已排除它们，等宽是第二道保险）；
/// - 可长按选中（`SelectableText`）：支持复制的人不必手抄；
/// - 显示剩余时间：码 5 分钟失效，看不到时限的人会反复抄同一个过期码。
class _ShortCodeCard extends StatelessWidget {
  const _ShortCodeCard({
    super.key,
    required this.code,
    required this.remaining,
    required this.miniProgramName,
  });

  final MiniProgramShortCode code;

  /// 剩余有效时长（由父级每秒重算）。
  final Duration remaining;

  /// 小程序名称（见 [LoginPage.miniProgramName]）。
  final String miniProgramName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final seconds = remaining.inSeconds;
    final expired = seconds <= 0;
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.lg,
        vertical: SpbSpacing.md,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(SpbRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Text(
            '在微信小程序里输入这个码',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: SpbSpacing.sm),
          SelectableText(
            code.displayCode,
            key: const ValueKey('login-short-code-value'),
            // 短码要「隔着桌子也能读」：headlineMedium（24）+ w700 + 字距 6。
            // 等宽 + CJK 兜底由 SpbType.mono 一并给出（§6.81）。
            style: SpbType.mono(textTheme, base: textTheme.headlineMedium)
                ?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                  color: scheme.onSurface,
                ),
          ),
          const SizedBox(height: SpbSpacing.sm),
          Text(
            expired ? '已过期，请重新发起' : '$mm:$ss 内有效',
            key: const ValueKey('login-short-code-ttl'),
            style: textTheme.bodySmall?.copyWith(
              color: expired ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

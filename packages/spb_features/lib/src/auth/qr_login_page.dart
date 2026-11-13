import 'package:flutter/material.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';

/// 扫码登录确认页（「手机上确认另一台设备的登录」）。
///
/// ## 页面在链路里的位置
///
/// 浏览器登录页出码 →（App Links / 系统相机扫码）→ 本页 → 用户点确认 →
/// 浏览器那边的轮询命中 `confirmed` 并拿到会话 cookie。
///
/// ## 为什么页面必须显示「发起端设备」
///
/// 这是整条链路**唯一**的反钓鱼手段（RFC 8628 §5.2）。攻击者可以自己出码、
/// 把二维码/链接发给受害者，受害者一确认，就把自己的账号登进了攻击者的浏览器
/// ——之后他在那台机器上看到的一切都属于受害者的账号。
///
/// 把 `43.174.246.24 · Windows · Chrome` 摊出来，受害者才有一个可以否定的信号。
/// 因此 [QrLoginPreview.device] **不提供默认折叠/省略的实现**，也不建议调用方
/// 在别处「美化」掉它。
///
/// ## 为什么两个按钮都要有
///
/// 只给「确认」等于逼用户二选一（确认 or 杀进程）。「不是我」必须把会话置成
/// 终态：服务端会拒绝后续任何账号的确认，浏览器侧立刻看到 denied 并提示重新
/// 出码——这是受害者能主动中断攻击的唯一动作。
///
/// ## 不做什么
///
/// - 不接收、不展示、不存储任何 token：登录态由浏览器与 IdP 之间流转；
/// - 不导航：确认成功后的去向由路由层决定（与登录页同一约定）；
/// - 不重试网络失败：确认是**幂等**的（服务端按账号幂等），用户可以再点一次，
///   但页面不该自作主张地循环重试——那会在用户已经决定「不是我」之后
///   又把请求补上去。
class QrLoginConfirmPage extends StatefulWidget {
  const QrLoginConfirmPage({
    super.key,
    required this.scene,
    required this.onLoad,
    required this.onConfirm,
    required this.onDeny,
    this.onDone,
  });

  /// 会话句柄（深链里带过来的）。
  final String scene;

  /// 读取预览（设备 + 当前账号 + 剩余时间）。失败抛 [SpbError]。
  final Future<QrLoginPreview> Function() onLoad;

  /// 确认登录。返回新状态。
  final Future<QrLoginStatus> Function() onConfirm;

  /// 拒绝登录。返回新状态。
  final Future<QrLoginStatus> Function() onDeny;

  /// 确认/拒绝完成后的回调（由路由层注入「关闭本页」之类的动作）。
  final void Function(QrLoginStatus status)? onDone;

  @override
  State<QrLoginConfirmPage> createState() => _QrLoginConfirmPageState();
}

enum _Phase { loading, ready, confirming, done, denied, failed }

class _QrLoginConfirmPageState extends State<QrLoginConfirmPage> {
  _Phase _phase = _Phase.loading;
  QrLoginPreview? _preview;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final preview = await widget.onLoad();
      if (!mounted) return;
      setState(() {
        _preview = preview;
        // 会话已经被处理过（重复点开同一条深链）：直接展示结果，
        // 不再给一个点了必然 409 的「确认」按钮。
        switch (preview.status) {
          case QrLoginStatus.confirmed:
            _phase = _Phase.done;
          case QrLoginStatus.denied:
            _phase = _Phase.denied;
          case QrLoginStatus.pending:
            _phase = _Phase.ready;
        }
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '读取扫码请求失败：$e';
      });
    }
  }

  Future<void> _act({required bool approve}) async {
    setState(() {
      _phase = _Phase.confirming;
      _error = null;
    });
    try {
      final status = approve ? await widget.onConfirm() : await widget.onDeny();
      if (!mounted) return;
      setState(() {
        _phase = status == QrLoginStatus.denied ? _Phase.denied : _Phase.done;
      });
      widget.onDone?.call(status);
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '操作失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码登录')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    switch (_phase) {
      case _Phase.loading:
        return const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: CircularProgressIndicator(),
          ),
        );

      case _Phase.done:
        return _ResultBlock(
          icon: Icons.verified_user_outlined,
          color: theme.colorScheme.primary,
          title: '已确认登录',
          message: '发起登录的那台设备已经登录成功，可以回到它继续操作。',
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('完成'),
            ),
          ],
        );

      case _Phase.denied:
        return _ResultBlock(
          icon: Icons.block_outlined,
          color: theme.colorScheme.error,
          title: '已拒绝登录',
          message:
              '本次登录已被取消，另一台设备需要重新出码。\n'
              '如果不是你本人操作的，建议立即修改密码。',
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('完成'),
            ),
          ],
        );

      case _Phase.failed:
        return _ResultBlock(
          icon: Icons.error_outline,
          color: theme.colorScheme.error,
          title: '无法处理这次扫码',
          message: _error ?? '请稍后重试。',
          actions: [
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('关闭'),
            ),
          ],
        );

      case _Phase.confirming:
      case _Phase.ready:
        final preview = _preview;
        final busy = _phase == _Phase.confirming;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.qr_code_scanner,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '是否在这台设备上登录？',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            _InfoCard(
              rows: [
                (
                  '发起设备',
                  // 不截断、不省略：这是判断「是不是我自己那台机器」的唯一依据。
                  preview?.device ?? '未知设备',
                ),
                ('登录账号', preview?.accountName ?? '当前账号'),
                if (preview?.expiresInSeconds != null)
                  ('剩余有效期', _formatRemaining(preview!.expiresInSeconds!)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '如果这不是你本人的操作，请点「不是我」。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: busy ? null : () => _act(approve: true),
              child: busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('确认登录'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: busy ? null : () => _act(approve: false),
              child: const Text('不是我，取消'),
            ),
          ],
        );
    }
  }

  String _formatRemaining(int seconds) {
    if (seconds <= 0) return '已过期';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return m > 0 ? '$m 分 $s 秒' : '$s 秒';
  }
}

/// 结果态（已确认 / 已拒绝 / 失败）的统一呈现。
class _ResultBlock extends StatelessWidget {
  const _ResultBlock({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.actions,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(icon, size: 48, color: color),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        for (final action in actions) ...[action, const SizedBox(height: 8)],
      ],
    );
  }
}

/// 「发起设备 / 登录账号 / 剩余有效期」三行信息卡。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: SpbRadius.cardAll,
      ),
      child: Column(
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      value,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

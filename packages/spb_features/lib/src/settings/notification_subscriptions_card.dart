import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_ui/spb_ui.dart';

/// 读取通知订阅额度（`GET /chat/miniapp/notifications/subscriptions`）。
typedef LoadNotificationSubscriptions =
    Future<List<MiniappNotificationSubscription>> Function();

/// 保存通知订阅额度（`POST` 同一路径）。
///
/// `accepted` 的语义见 [MiniappNotificationSubscription]：`n > 0` 累加额度，
/// `n == 0` 归零并禁用。返回保存后的完整列表。
typedef SaveNotificationSubscriptions =
    Future<List<MiniappNotificationSubscription>> Function(
      Map<String, int> accepted,
    );

/// 通知订阅区块（小程序订阅消息额度）。
///
/// ## 为什么是一个自管状态的区块，而不是并进设置页的 draft
///
/// 设置页的同步配置是「改动先留内存、点保存才落盘」（见 [SettingsPage] 的
/// 表单语义）。通知额度**不能**用这套：它是服务端账本（`miniapp_subscriptions`
/// 表），没有「草稿」的概念——本地攒一个「待开启」状态再提交，只会让 UI 与
/// 服务端事实脱节。故本区块自己管状态、切换即提交。
///
/// ## 为什么必须按白名单渲染，而不是按响应渲染
///
/// `ListByUser` 只返回**已存在的行**（`SELECT ... WHERE user_id = ?`），新用户
/// 一行都没有 → 响应是空列表。若按响应渲染，新用户看到的是「暂无通知设置」，
/// 而实际上四个模板都可用（额度 0、未开启）。故这里**始终**遍历
/// [MiniappNotificationTemplates.all]，响应只用来查缺补漏。
///
/// ## 503 是「暂时不可用」，不是「失败」
///
/// 数据库不可用时服务端返回 503（`miniapp.go` 的 `h.dep.DB == nil` 分支），
/// 不是 500。这类失败**重试就能好**，文案若写成「加载失败」会让用户以为
/// 设置坏了、去反复改；写成「暂时不可用」并给一个重试入口才准确。
class NotificationSubscriptionsCard extends StatefulWidget {
  const NotificationSubscriptionsCard({
    super.key,
    required this.load,
    required this.save,
    this.title = '通知订阅',
  });

  final LoadNotificationSubscriptions load;
  final SaveNotificationSubscriptions save;

  final String title;

  @override
  State<NotificationSubscriptionsCard> createState() =>
      _NotificationSubscriptionsCardState();
}

class _NotificationSubscriptionsCardState
    extends State<NotificationSubscriptionsCard> {
  /// 服务端返回的行，按 template_key 索引。
  ///
  /// 缺失的 key 不在表里（新用户、或从未授权过的模板）——查询方负责回落成
  /// 「额度 0 / 未开启」。
  Map<String, MiniappNotificationSubscription> _subs = const {};

  bool _loading = true;

  /// 暂时不可用（503）——与「真的出错了」区分开，见类文档。
  bool _unavailable = false;
  String? _error;

  /// 正在提交的 key（逐行禁用，避免连点造成并发的额度加减）。
  final _saving = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _unavailable = false;
      _error = null;
    });
    try {
      final items = await widget.load();
      if (!mounted) return;
      setState(() {
        _subs = {for (final s in items) s.templateKey: s};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unavailable = _isUnavailable(e);
        _error = _unavailable ? null : _describe(e);
      });
    }
  }

  /// 503（及任何 5xx 之外的「服务端还没准备好」信号）都按「暂时不可用」处理。
  static bool _isUnavailable(Object e) =>
      e is HttpError && (e.statusCode == 503 || e.statusCode == 502);

  String _describe(Object e) => e is SpbError ? e.message : '$e';

  /// 取某 key 的服务端状态；无记录时回落为「额度 0、未开启」。
  MiniappNotificationSubscription _sub(String key) =>
      _subs[key] ??
      MiniappNotificationSubscription(
        templateKey: key,
        remainingQuota: 0,
        enabled: false,
      );

  Future<void> _toggle(String key, bool enabled) async {
    if (_saving.contains(key)) return;
    setState(() => _saving.add(key));
    try {
      // n > 0 累加额度（AddQuota）、n == 0 归零并禁用（ResetQuota）。
      //
      // ⚠️ **微信侧的真实授权来自 `wx.requestSubscribeMessage` 弹窗**（用户
      // 手势内发起，一次 accept = 一条额度）。服务端 `AddQuota` 只是本地账本，
      // 它不代替那次弹窗。故本开关的「开启」在微信小程序语境下应当由弹窗
      // 结果驱动；这里是 Flutter 端（非微信环境）的手动入口，语义上等价于
      // 「我确认要接收这类通知」。真正的下发仍取决于微信侧是否还有额度。
      final items = await widget.save({key: enabled ? 1 : 0});
      if (!mounted) return;
      setState(() {
        _subs = {for (final s in items) s.templateKey: s};
        _saving.remove(key);
        _unavailable = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving.remove(key);
        _unavailable = _isUnavailable(e);
        _error = _unavailable ? null : _describe(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(widget.title, highlight: true),
        Card(
          key: const ValueKey('settings-notifications'),
          margin: EdgeInsets.zero,
          child: _buildBody(),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(SpbSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_unavailable) {
      return ListTile(
        key: const ValueKey('settings-notifications-unavailable'),
        leading: const Icon(Icons.cloud_off_outlined),
        title: const Text('通知订阅暂时不可用'),
        subtitle: const Text('服务端数据库未就绪，稍后重试即可'),
        trailing: TextButton(
          key: const ValueKey('settings-notifications-retry'),
          onPressed: _load,
          child: const Text('重试'),
        ),
      );
    }

    return Column(
      children: [
        for (final key in MiniappNotificationTemplates.all) ...[
          if (key != MiniappNotificationTemplates.all.first)
            const Divider(height: 1),
          _buildRow(key),
        ],
        if (_error != null) ...[
          const Divider(height: 1),
          Padding(
            padding: SpbSpacing.cardPadding,
            child: ErrorBanner(
              key: const ValueKey('settings-notifications-error'),
              message: _error!,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRow(String key) {
    final sub = _sub(key);
    final reserved = _isReserved(key);
    return SwitchListTile(
      key: ValueKey('settings-notification-$key'),
      value: sub.enabled,
      // 预留 key 也能切（服务端白名单放行、写入会成功），但文案要说清它当前
      // 没有生产者——否则用户会以为「打开 work_failed 就能收到失败通知」。
      onChanged: _saving.contains(key) ? null : (v) => _toggle(key, v),
      title: Text(_label(key)),
      subtitle: Text(_subtitle(sub, reserved)),
      secondary: _saving.contains(key)
          ? const SizedBox(
              width: SpbSpacing.xl,
              height: SpbSpacing.xl,
              child: Padding(
                padding: EdgeInsets.all(SpbSpacing.xs),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : null,
    );
  }

  /// 当前**没有生产者**的 key（服务端 `TemplateMap` 里标注「预留」）。
  ///
  /// 依据：`apps/go-api/internal/notifications/dispatcher.go` 的
  /// `TemplateMap` 注释与 `OutboxService` 的两个 enqueue 调用点——它们都只写
  /// `TemplateNotify`。故 `work_failed` / `confirmation_required` 虽在白名单里，
  /// 却没有任何事件会消耗它们的额度。
  static bool _isReserved(String key) =>
      key == MiniappNotificationTemplates.workFailed ||
      key == MiniappNotificationTemplates.confirmationRequired;

  static String _label(String key) => switch (key) {
    MiniappNotificationTemplates.notify => '任务通知',
    MiniappNotificationTemplates.workCompleted => '任务完成',
    MiniappNotificationTemplates.workFailed => '任务失败',
    MiniappNotificationTemplates.confirmationRequired => '待确认提醒',
    _ => key,
  };

  static String _subtitle(MiniappNotificationSubscription sub, bool reserved) {
    final quota = '剩余 ${sub.remainingQuota} 条';
    if (reserved) return '$quota · 服务端暂未启用该事件';
    return quota;
  }
}

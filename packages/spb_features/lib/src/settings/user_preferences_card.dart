import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_ui/spb_ui.dart';

/// 读取用户偏好（`GET /me/preferences`）。
typedef LoadUserPreferences = Future<UserPreferences> Function();

/// 保存用户偏好（`PUT /me/preferences`），返回服务端**回读的生效值**。
///
/// ## 为什么参数是「可空 + 具名」而不是一个完整的偏好对象
///
/// 服务端是**部分更新**语义（未提交的键保持原值），且显式拒绝空 body。若传一个
/// 完整对象，调用方就得自己决定「哪些字段算改过」——而它没有编辑前的基线。
/// 收成可空具名参数后，语义变为：**非 null 即提交**，null 即不动。
///
/// ⚠️ 空串是**有效值**（清除 / 恢复默认），不是「不传」：
/// - `displayName: ''` 清除自设昵称（展示侧回落 `users.name`）；
/// - `avatarUrl: ''` 清除自设头像；
/// - `defaultAgentId: ''` 恢复「跟随系统默认」；
/// - `replyLanguage` 用 `'auto'`（不是空串）表达「跟随输入」。
typedef SaveUserPreferences = Future<UserPreferences> Function({
  String? displayName,
  String? avatarUrl,
  String? replyLanguage,
  String? defaultAgentId,
});

/// 「默认 Agent」下拉的一项。
///
/// ## 为什么在这里定义而不是等 `spb_models` 出 Agent 契约
///
/// 本卡片只需要 `id` + 展示名两个字段，不需要 Agent 的完整 DTO（provider /
/// skills / status ...）。收一个最小类型让本区块能独立测试；装配层从
/// agent 列表映射过来即可（`PreferenceAgentOption(id: a.id, name: a.name)`）。
class PreferenceAgentOption {
  const PreferenceAgentOption({required this.id, required this.name});

  final String id;

  /// 展示名。为空时回退 [id]（显示空白会让用户不知道这是哪个 agent）。
  final String name;

  String get label => name.isEmpty ? id : name;

  @override
  String toString() => 'PreferenceAgentOption($id, $name)';
}

/// 头像地址的展示层 sanitize：只接受 `http` / `https`。
///
/// ## 为什么校验在展示层而不是服务端
///
/// 服务端下发/存储前**不做** URL 校验（见 Go `user_preferences.go` 的
/// `AvatarURL` 注释）：若在写入时拒绝，用户会看到「保存成功但值不见了」。
/// 故校验落在渲染侧。
///
/// ## 为什么只放行 http/https
///
/// 头像会进 `<img src>` 之类的渲染路径。放行 `javascript:` / `data:` /
/// `file:` 等 scheme 等于给一个用户可控的字符串开了本地文件读取与脚本执行面。
///
/// 返回 null 表示不可用（调用方渲染内置图标）。空串不是「非法」而是「未设置」，
/// 故调用方应先判空再调用本函数。
String? sanitizeAvatarUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  // `http://` 这种「有 scheme 无 host」的串能过 Uri.tryParse，但渲染时什么都
  // 加载不出来——当成非法，避免用户以为存了个有效地址。
  if (uri.host.isEmpty) return null;
  return value;
}

/// 用户偏好区块（昵称 / 头像 / 回复语言 / 默认 Agent）。
///
/// ## 为什么自管状态，不并进设置页的 draft
///
/// 设置页的同步配置是「改动先留内存、点保存才落盘」的**整份提交**语义。
/// 用户偏好是服务端资源，且服务端只做**部分更新**——并进 draft 会强迫调用方
/// 在一份不含这些字段的对象里表示它们，反而容易把「没改」误报成「改成默认」。
/// 本区块自己管基线（[_saved]）与草稿，保存时只提交**与基线不同**的字段。
///
/// ## 为什么语言选项来自响应而不是硬编码
///
/// `available_languages` + `language_labels` 由服务端下发（真源
/// `userpref.SupportedLanguages()` / `LanguageLabel`）。硬编码一份的后果是
/// 「后端新增一门语言」必须改客户端并发版（小程序还得重新提审）。缺键时回退
/// 原始标签，不显示空白。
///
/// ## 空串是合法状态，不是「缺失」
///
/// `default_agent_id` 空串 = 「自动（跟随系统默认）」；`display_name` 空串 =
/// 未设置（展示侧回落 `users.name` → `email`）。两者都**必须**渲染成有意义的
/// 文案——渲染成空白项会让用户以为设置坏了。
class UserPreferencesCard extends StatefulWidget {
  const UserPreferencesCard({
    super.key,
    required this.load,
    required this.save,
    this.agentOptions = const [],
    this.fallbackDisplayName = '',
    this.title = '个人偏好',
  });

  final LoadUserPreferences load;
  final SaveUserPreferences save;

  /// 「默认 Agent」下拉的可选项（装配层从 agent 列表映射）。
  ///
  /// 为空时下拉只有「自动」一项——不是错误状态，只是本端还没接 agent 列表。
  final List<PreferenceAgentOption> agentOptions;

  /// 昵称未设置时的回落值（`users.name` → `email`），仅用于输入框占位提示。
  ///
  /// ## 为什么由装配层传入，而不是卡片自己去问
  ///
  /// 回落链的真源在 `GET /api/auth/me`（服务端已解析好），本卡片只接
  /// `spb_models` + 注入回调，不碰 `spb_api`（与 [NotificationSubscriptionsCard]
  /// 同一约定）。
  final String fallbackDisplayName;

  final String title;

  @override
  State<UserPreferencesCard> createState() => _UserPreferencesCardState();
}

class _UserPreferencesCardState extends State<UserPreferencesCard> {
  /// 服务端权威值（判断「哪些字段被改过」的基线）。
  UserPreferences? _saved;

  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  /// 保存成功的短暂反馈。
  bool _savedFlash = false;

  late final TextEditingController _displayName;
  late final TextEditingController _avatarUrl;

  /// 草稿里的回复语言 / 默认 Agent（null = 未改动）。
  String? _replyLanguage;
  String? _defaultAgentId;

  @override
  void initState() {
    super.initState();
    _displayName = TextEditingController();
    _avatarUrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _displayName.dispose();
    _avatarUrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final prefs = await widget.load();
      if (!mounted) return;
      setState(() {
        _applyAuthoritative(prefs);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _describe(e);
      });
    }
  }

  /// 用权威值重置草稿与基线。
  void _applyAuthoritative(UserPreferences prefs) {
    _saved = prefs;
    _displayName.text = prefs.displayName;
    _avatarUrl.text = prefs.avatarUrl;
    _replyLanguage = prefs.replyLanguage;
    _defaultAgentId = prefs.defaultAgentId;
    _savedFlash = false;
  }

  /// 草稿里的昵称 / 头像（含用户尚未提交的编辑）。
  String get _draftDisplayName => _displayName.text.trim();
  String get _draftAvatar => _avatarUrl.text.trim();

  /// 头像输入非法时的提示；null 表示可用（含「空 = 未设置」）。
  String? get _avatarError {
    final raw = _draftAvatar;
    if (raw.isEmpty) return null;
    return sanitizeAvatarUrl(raw) == null ? '已忽略非法地址：只接受 http/https 链接' : null;
  }

  /// 相对基线的改动集合。
  ///
  /// ## 为什么逐字段比对而不是「提交全部草稿」
  ///
  /// 服务端是部分更新语义。提交全部字段会把用户**没碰过**的字段也重写一遍：
  /// 若另一台设备刚改了回复语言，本端点一次「保存」就会把它盖回去。
  ({
    String? displayName,
    String? avatarUrl,
    String? replyLanguage,
    String? defaultAgentId,
  })
  get _pendingChanges {
    final saved = _saved;
    if (saved == null) {
      return (
        displayName: null,
        avatarUrl: null,
        replyLanguage: null,
        defaultAgentId: null,
      );
    }
    return (
      displayName: _draftDisplayName == saved.displayName
          ? null
          : _draftDisplayName,
      // 非法地址不提交（见 [_avatarError]）：提交它等于把垃圾存进服务端，
      // 用户下次进来又会看到「非法」提示，形成循环。
      avatarUrl: _avatarError != null || _draftAvatar == saved.avatarUrl
          ? null
          : _draftAvatar,
      replyLanguage: _replyLanguage == saved.replyLanguage
          ? null
          : _replyLanguage,
      defaultAgentId: _defaultAgentId == saved.defaultAgentId
          ? null
          : _defaultAgentId,
    );
  }

  bool get _hasChanges {
    final p = _pendingChanges;
    return p.displayName != null ||
        p.avatarUrl != null ||
        p.replyLanguage != null ||
        p.defaultAgentId != null;
  }

  /// 非法头像地址时禁止保存。
  ///
  /// 只禁用、不静默丢弃：若「保存成功但头像没变」，用户会反复重试而不知道原因
  /// （服务端注释里描述的正是这个坑）。字段下方的错误文案给出改法。
  bool get _canSave => _hasChanges && _avatarError == null && !_saving;

  Future<void> _save() async {
    if (!_canSave) return;
    final p = _pendingChanges;
    setState(() => _saving = true);
    try {
      final updated = await widget.save(
        displayName: p.displayName,
        avatarUrl: p.avatarUrl,
        replyLanguage: p.replyLanguage,
        defaultAgentId: p.defaultAgentId,
      );
      if (!mounted) return;
      setState(() {
        // 用服务端**回读的生效值**覆盖本地：服务端可能归一化（如非法语言已
        // 在客户端被拦，但 `auto` 会被转成「删记录」），本地乐观值可能与
        // 服务端事实不符。
        _applyAuthoritative(updated);
        _saving = false;
        _savedFlash = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _loadError = _describe(e);
      });
    }
  }

  /// 把错误翻成用户能看懂的一句话。
  ///
  /// `HttpError.message` 恒为 `"HTTP 400"`，服务端文案在 `body` 里
  /// （见 `ChatApi._unwrap`），故必须从 body 提取，不能直接显示 message。
  static String _describe(Object e) {
    if (e is HttpError) {
      final detail = _serverDetail(e.body);
      if (detail != null) {
        // 非法语言值是最常见的 400（服务端显式拒绝而非静默回落），给一句
        // 带改法的文案。
        if (e.statusCode == 400 && detail.contains('reply_language')) {
          return '不支持这个回复语言，请从列表里重新选择';
        }
        return detail;
      }
      return e.statusCode == 401 ? '登录已过期，请重新登录' : '保存失败（HTTP ${e.statusCode}）';
    }
    if (e is NetworkError) return '网络连接失败，请检查网络后重试';
    return e is SpbError ? e.message : '$e';
  }

  /// 从错误体里取服务端文案（`message` 优先，`error` 兜底）。
  ///
  /// `HttpError.body` 是 `data.toString()` 的结果——Dio 已把响应体解析成 Map，
  /// 故它实际是 **Dart Map 字面量**（键与字符串值都不带引号），不是 JSON。
  /// 两种形态都要认，否则真实响应上会静默提取不到。
  static String? _serverDetail(String? body) {
    if (body == null || body.isEmpty) return null;
    for (final key in const ['message', 'error']) {
      final json = RegExp('["\']$key["\']\\s*:\\s*["\']([^"\']+)["\']')
          .firstMatch(body);
      if (json != null) return json.group(1)?.trim();
      final bare = RegExp('(?:^|[{,\\s])$key:\\s*([^,}]+)').firstMatch(body);
      if (bare != null) {
        final v = bare.group(1)?.trim();
        if (v != null && v.isNotEmpty) return v;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(widget.title, highlight: true),
        Card(
          key: const ValueKey('settings-user-preferences'),
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
    // 首次加载失败：整块退化为错误 + 重试。没有基线时**不渲染表单**——
    // 空的输入框看起来像「你的偏好是空的」，用户可能就此覆盖掉真实值。
    if (_saved == null) {
      return ListTile(
        key: const ValueKey('settings-prefs-load-error'),
        leading: const Icon(Icons.error_outline),
        title: const Text('读取个人偏好失败'),
        subtitle: Text(_loadError ?? '未知错误'),
        trailing: TextButton(
          key: const ValueKey('settings-prefs-retry'),
          onPressed: _load,
          child: const Text('重试'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: SpbSpacing.cardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildDisplayName(context),
              const SizedBox(height: SpbSpacing.md),
              _buildAvatar(context),
              const SizedBox(height: SpbSpacing.md),
              _buildReplyLanguage(context),
              const SizedBox(height: SpbSpacing.md),
              _buildDefaultAgent(context),
            ],
          ),
        ),
        // 保存期错误（服务端拒绝 / 网络失败）就地展示。
        if (_loadError != null) ...[
          const Divider(height: 1),
          Padding(
            padding: SpbSpacing.cardPadding,
            child: ErrorBanner(
              key: const ValueKey('settings-prefs-error'),
              message: _loadError!,
            ),
          ),
        ],
        if (_hasChanges || _saving || _savedFlash) ...[
          const Divider(height: 1),
          Padding(
            padding: SpbSpacing.cardPadding,
            child: Row(
              children: [
                if (_savedFlash)
                  const Expanded(
                    child: Row(
                      key: ValueKey('settings-prefs-saved'),
                      children: [
                        Icon(Icons.check_circle_outline, size: SpbSpacing.lg),
                        SizedBox(width: SpbSpacing.xs),
                        Text('已保存'),
                      ],
                    ),
                  )
                else
                  const Spacer(),
                FilledButton(
                  key: const ValueKey('settings-prefs-save'),
                  // 非法头像地址时禁用：见 [_canSave] 的说明。
                  onPressed: _canSave ? _save : null,
                  child: _saving
                      ? const SizedBox(
                          width: SpbSpacing.lg,
                          height: SpbSpacing.lg,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDisplayName(BuildContext context) {
    final fallback = widget.fallbackDisplayName;
    return TextField(
      key: const ValueKey('settings-prefs-display-name'),
      controller: _displayName,
      enabled: !_saving,
      // 占位显示回落值：用户一眼能看到「不填的话会显示成什么」。
      decoration: InputDecoration(
        labelText: '昵称',
        hintText: fallback.isEmpty ? '未设置' : fallback,
        helperText: '留空则显示账号名称',
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _buildAvatar(BuildContext context) {
    final raw = _draftAvatar;
    final valid = raw.isEmpty ? null : sanitizeAvatarUrl(raw);
    final error = _avatarError;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 预览：合法地址显示图片，否则内置图标（非法地址也回退到图标，
        // 不尝试加载）。
        _AvatarPreview(
          key: const ValueKey('settings-prefs-avatar-preview'),
          url: valid,
        ),
        const SizedBox(width: SpbSpacing.md),
        Expanded(
          child: TextField(
            key: const ValueKey('settings-prefs-avatar-url'),
            controller: _avatarUrl,
            enabled: !_saving,
            decoration: InputDecoration(
              labelText: '头像链接',
              hintText: 'https://example.com/avatar.png',
              helperText: '只接受 http / https 链接',
              errorText: error,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ],
    );
  }

  Widget _buildReplyLanguage(BuildContext context) {
    final prefs = _saved!;
    // 选项来自服务端下发的有序列表，展示名查 `language_labels`，缺键回退原始
    // 标签（硬编码列表会让「后端加语言」必须改客户端并发版）。
    final languages = prefs.availableLanguages.isEmpty
        ? [kLanguageAuto]
        : prefs.availableLanguages;
    final value = languages.contains(_replyLanguage)
        ? _replyLanguage
        : kLanguageAuto;
    return DropdownButtonFormField<String>(
      key: const ValueKey('settings-prefs-reply-language'),
      initialValue: value,
      decoration: const InputDecoration(
        labelText: '回复语言',
        helperText: '「跟随输入」由模型按你消息的语言回复',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final tag in languages)
          DropdownMenuItem(value: tag, child: Text(prefs.languageLabel(tag))),
      ],
      onChanged: _saving ? null : (v) => setState(() => _replyLanguage = v),
    );
  }

  Widget _buildDefaultAgent(BuildContext context) {
    // 已选的 agent 可能不在列表里（被归档/删除，而列表只含 active）。若直接
    // 把它塞进 DropdownButton 而 items 里没有，Flutter 会抛断言。故补一条
    // 「（已失效）」项——比静默把它改写成「自动」诚实：用户能看到自己配过什么。
    final options = widget.agentOptions;
    final current = _defaultAgentId ?? '';
    final missing = current.isNotEmpty && !options.any((o) => o.id == current);
    return DropdownButtonFormField<String>(
      key: const ValueKey('settings-prefs-default-agent'),
      initialValue: current,
      decoration: const InputDecoration(
        labelText: '默认 Agent',
        helperText: '新对话未指定 agent 时使用',
        border: OutlineInputBorder(),
      ),
      items: [
        // 空串 = 自动。必须渲染成有文案的一项，不能是空白项。
        const DropdownMenuItem(value: '', child: Text('自动（跟随系统默认）')),
        for (final o in options)
          DropdownMenuItem(value: o.id, child: Text(o.label)),
        if (missing)
          DropdownMenuItem(value: current, child: Text('$current（已失效）')),
      ],
      onChanged: _saving ? null : (v) => setState(() => _defaultAgentId = v),
    );
  }
}

/// 头像预览：合法地址加载图片，否则（未设置 / 非法）显示内置图标。
///
/// ## 为什么不用 `CircleAvatar.backgroundImage`
///
/// 它由 `ImageProvider` 直接驱动渲染，**加载失败时会抛异常进 Flutter 错误
/// 通道**（widget test 里表现为测试失败）。而头像地址是用户自由输入、服务端
/// 又不做校验的字符串，加载失败是**预期内**的（链接过期、域名写错、外网不通）。
/// 故用 `Image.network` 的 `errorBuilder` 把失败降级成内置图标——比弹一个红屏
/// 或让整个设置页崩掉诚实得多。
class _AvatarPreview extends StatelessWidget {
  const _AvatarPreview({super.key, this.url});

  /// 已 sanitize 的地址；null = 未设置或非法（渲染内置图标）。
  final String? url;

  @override
  Widget build(BuildContext context) {
    const fallback = Icon(Icons.person_outline, size: SpbSpacing.lg);
    return CircleAvatar(
      radius: SpbSpacing.lg,
      child: url == null
          ? fallback
          : ClipOval(
              child: Image.network(
                url!,
                width: SpbSpacing.xxl,
                height: SpbSpacing.xxl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
            ),
    );
  }
}

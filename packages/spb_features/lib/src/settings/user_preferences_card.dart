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
///
/// ## 两个 bool 的语义
///
/// [followUpSuggest] / [habitSuggest] 是**新建对话的默认播种值**，仅影响之后
/// 新建的 group，不回溯修改既有 group（服务端 `user_preferences.go`）。与群级
/// 同名开关是不同层次：本处是「以后新建的默认」，群级那个是「这个对话现在
/// 开不开」。
///
/// 它们同样遵循「非 null 即提交」：传 `false` 是**有意义的显式关闭**，与
/// 「不传」（保持原值）必须区分——若写成 `if (x == true)` 就永远关不掉。
///
/// ## [habitNotifyChannels] 是**单个逗号分隔字符串**，不是数组
///
/// 服务端把它当不透明串存取（`userpref` 层），故这里也不拆成列表：
/// - `''` = 未设置（服务端删记录 → 回退「最近入站渠道」）；
/// - `'off'`（[kHabitNotifyOff]）= 显式关闭推送；
/// - `'wechat_ilink,dingtalk'` = 只推这些渠道。
///
/// 三者语义互不相同，尤其是 `''` 与 `'off'`——**不能**用「空列表」表达关闭。
typedef SaveUserPreferences = Future<UserPreferences> Function({
  String? displayName,
  String? avatarUrl,
  String? replyLanguage,
  String? defaultAgentId,
  bool? followUpSuggest,
  bool? habitSuggest,
  String? habitNotifyChannels,
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

/// 用户偏好区块（昵称 / 头像 / 回复语言 / 默认 Agent / 两个新建默认开关 /
/// 习惯推送渠道）。
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

  /// 草稿里的两个「新建对话默认值」开关。
  ///
  /// 与 [_replyLanguage] 同形：初值来自权威值，`_pendingChanges` 逐字段比对。
  bool? _followUpSuggest;
  bool? _habitSuggest;

  /// 草稿里的习惯推送渠道（勾选集合 + 显式关闭标志）。
  ///
  /// ## 为什么是两个字段而不是一个字符串
  ///
  /// 线格式（[_channelsToWire]）里 `''`（恢复自动）与 `'off'`（显式关闭）
  /// 都「没有渠道」，但它们是**两个相反的动作**，UI 必须能区分——用一个字符串
  /// 表达会把「用户点了关闭」变成「用户清空了选择」→ 服务端删记录 → 回退自动，
  /// 推送反而重新打开了。
  Set<String> _habitChannels = <String>{};
  bool _habitChannelsOff = false;

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
    _followUpSuggest = prefs.followUpSuggest;
    _habitSuggest = prefs.habitSuggest;
    _habitChannels = prefs.selectedHabitChannels.toSet();
    // `habitNotifyDisabled` 同时覆盖「存了 off」与「set=true 但值为空」
    // （两者服务端语义相同：不推送），与 webapp 的 `isOff` 同口径。
    _habitChannelsOff = prefs.habitNotifyDisabled;
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

  /// 把渠道草稿编成服务端线格式（**单个逗号分隔串**，见 [SaveUserPreferences]）。
  ///
  /// 三态互斥，且 `''` 与 `'off'` 语义相反：
  /// - 显式关闭 → `'off'`（[kHabitNotifyOff]）；
  /// - 一个都没勾 → `''`（服务端删记录 → 回退「最近入站渠道」）；
  /// - 勾了若干 → 逗号连接。
  ///
  /// ## 为什么要排序
  ///
  /// 同一集合必须编出**同一个串**，否则 `_pendingChanges` 会因勾选顺序不同而
  /// 误判为「有改动」，保存按钮在没真改的情况下亮起来。
  static String _channelsToWire(Set<String> selected, bool off) {
    if (off) return kHabitNotifyOff;
    if (selected.isEmpty) return '';
    final sorted = selected.toList()..sort();
    return sorted.join(',');
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
    bool? followUpSuggest,
    bool? habitSuggest,
    String? habitNotifyChannels,
  })
  get _pendingChanges {
    final saved = _saved;
    if (saved == null) {
      return (
        displayName: null,
        avatarUrl: null,
        replyLanguage: null,
        defaultAgentId: null,
        followUpSuggest: null,
        habitSuggest: null,
        habitNotifyChannels: null,
      );
    }
    // 两侧都过同一个编码函数，故 `' wechat , dingtalk '` 这类脏存量值与
    // 排序后的草稿能正确判定为「无改动」（否则会平白亮起保存按钮）。
    final channels = _channelsToWire(_habitChannels, _habitChannelsOff);
    final savedChannels = _channelsToWire(
      saved.selectedHabitChannels.toSet(),
      saved.habitNotifyDisabled,
    );
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
      followUpSuggest: _followUpSuggest == saved.followUpSuggest
          ? null
          : _followUpSuggest,
      habitSuggest: _habitSuggest == saved.habitSuggest ? null : _habitSuggest,
      habitNotifyChannels: channels == savedChannels ? null : channels,
    );
  }

  bool get _hasChanges {
    final p = _pendingChanges;
    return p.displayName != null ||
        p.avatarUrl != null ||
        p.replyLanguage != null ||
        p.defaultAgentId != null ||
        p.followUpSuggest != null ||
        p.habitSuggest != null ||
        p.habitNotifyChannels != null;
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
        followUpSuggest: p.followUpSuggest,
        habitSuggest: p.habitSuggest,
        habitNotifyChannels: p.habitNotifyChannels,
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
              const SizedBox(height: SpbSpacing.md),
              _buildNewGroupDefaults(context),
              const SizedBox(height: SpbSpacing.md),
              _buildHabitNotifyChannels(context),
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

  /// 两个「新建对话默认值」开关。
  ///
  /// ## 与群级同名开关的关系
  ///
  /// 这里只影响**之后新建**的对话（服务端建组时播种到 metadata）。既有对话
  /// 不受影响——文案必须说清，否则用户改完默认值去老对话里找不到变化，会以为
  /// 设置没生效。
  Widget _buildNewGroupDefaults(BuildContext context) {
    final theme = Theme.of(context);
    final saved = _saved!;
    // 草稿优先，未初始化时用权威值（`_applyAuthoritative` 已赋，此处仅是保险）。
    final followUp = _followUpSuggest ?? saved.followUpSuggest;
    final habit = _habitSuggest ?? saved.habitSuggest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('新建对话的默认开关', style: theme.textTheme.labelLarge),
        SwitchListTile(
          key: const ValueKey('pref-follow-up-suggest'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: followUp,
          onChanged: _saving
              ? null
              : (v) => setState(() => _followUpSuggest = v),
          title: const Text('默认开启「后续提问建议」'),
          subtitle: const Text('仅影响之后新建的对话，不回溯修改既有对话'),
        ),
        SwitchListTile(
          key: const ValueKey('pref-habit-suggest'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: habit,
          onChanged: _saving ? null : (v) => setState(() => _habitSuggest = v),
          title: const Text('默认开启「习惯建议」'),
          subtitle: const Text('仅影响之后新建的对话，不回溯修改既有对话'),
        ),
      ],
    );
  }

  /// 习惯结果推送渠道（多选 + 关闭 / 恢复自动）。
  ///
  /// ## 选项必须来自服务端下发的 `available_channels`
  ///
  /// 渠道白名单真源在 mq-server（跨仓），中文名真源在 Go `outboundchannel`。
  /// 客户端硬编码必然漂移，且允许用户选一个**没绑定**的渠道 = 保证推送失败。
  ///
  /// ## 三个状态必须区分（与 webapp 同口径）
  ///
  /// | 状态 | 判据 | 展示 |
  /// |---|---|---|
  /// | 自动（未设置） | `!habitNotifyChannelsSet` | 「自动」徒标 + 无勾选 |
  /// | 已关闭 | `habitNotifyDisabled` | 「已关闭」徒标 |
  /// | 已配置 | 其它 | 「已配置」徒标 + 勾选 |
  ///
  /// 只看 `habitNotifyChannels` 无法区分前两者（都是空）——而它们语义相反：
  /// 未设置应显示默认选中项，已关闭应显示「不再推送」。
  Widget _buildHabitNotifyChannels(BuildContext context) {
    final theme = Theme.of(context);
    final saved = _saved!;
    final options = saved.availableChannels;

    // 「已配置但渠道已全部失效」：配置还在（set=true）但可选项里已没有它。
    final staleSelected =
        saved.habitNotifyChannelsSet &&
        saved.selectedHabitChannels.isNotEmpty &&
        !saved.selectedHabitChannels.any(
          (v) => options.any((o) => o.value == v),
        );

    // 无可用渠道且未显式关闭：用户没绑定任何可推送渠道，无从选择。
    //
    // 看草稿而非基线：用户点「关闭推送」后（草稿 off），这条提示应立即消失
    // （此时确实「无需选择」），否则会跟按钮文案（已是「恢复自动」）自相矛盾。
    final noChannels = options.isEmpty && !_habitChannelsOff;

    // 徒标也看草稿：勾选态已是草稿，徒标若看基线，用户点关闭后勾选框已清空、
    // 徒标却还写着「已配置」，二者在保存前就已经不一致。
    final badgeLabel = _habitChannelsOff
        ? '已关闭'
        : _habitChannels.isNotEmpty
        ? '已配置'
        : '自动';

    return Column(
      key: const ValueKey('pref-habit-notify-channels'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('习惯结果推送渠道', style: theme.textTheme.labelLarge),
            const SizedBox(width: SpbSpacing.sm),
            Container(
              key: const ValueKey('pref-habit-notify-badge'),
              padding: const EdgeInsets.symmetric(
                horizontal: SpbSpacing.sm,
                vertical: SpbSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: SpbRadius.cardAll,
              ),
              child: Text(badgeLabel, style: theme.textTheme.labelSmall),
            ),
          ],
        ),
        const SizedBox(height: SpbSpacing.xs),
        Text(
          '习惯到点执行完后，把实际回复推送到这些 IM 渠道',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: SpbSpacing.sm),
        if (noChannels)
          Text(
            '你还没有绑定任何可推送的渠道，无法选择',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else ...[
          for (final opt in options)
            CheckboxListTile(
              key: ValueKey('pref-habit-channel-${opt.value}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _habitChannels.contains(opt.value),
              // 关闭态下勾选框仍可点：点一下即隐含「重新开启推送」。
              // 否则用户得先找到「恢复自动」才能再选，多一步且不直观。
              onChanged: _saving
                  ? null
                  : (checked) => setState(() {
                      if (checked == true) {
                        _habitChannels.add(opt.value);
                      } else {
                        _habitChannels.remove(opt.value);
                      }
                      // 任何手动勾选都意味着「不再是显式关闭」。
                      _habitChannelsOff = false;
                    }),
              title: Text(opt.label),
            ),
        ],
        if (staleSelected)
          Padding(
            padding: const EdgeInsets.only(top: SpbSpacing.xs),
            child: Text(
              '你选的渠道已失效（可能已解绑），请重新选择',
              key: const ValueKey('pref-habit-notify-stale'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (!noChannels) ...[
          const SizedBox(height: SpbSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('pref-habit-notify-toggle-off'),
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      // 单动作切换：关闭 ⇄ 恢复自动。
                      //
                      // 不要求用户自己清空勾选：那会把「关闭」与「清空」两种
                      // 相反意图混为一谈（清空 = 删记录 = 回退自动，推送反而
                      // 重新打开）。
                      final off = !_habitChannelsOff;
                      _habitChannelsOff = off;
                      if (off) _habitChannels.clear();
                    }),
              child: Text(_habitChannelsOff ? '恢复自动' : '关闭推送'),
            ),
          ),
        ],
      ],
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

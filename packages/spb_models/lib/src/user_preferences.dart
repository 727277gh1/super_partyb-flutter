/// 用户偏好（`GET|PUT /me/preferences`）。
///
/// 对应 Go 侧 `internal/server/user_preferences.go` 的 `userPrefResponse`。
///
/// ## 空串是**合法状态**，不是「字段缺失」
///
/// 三个字段的空串各有明确语义，**不得**当成 null 或「未设置」处理：
///
/// | 字段 | 空串的含义 |
/// |---|---|
/// | `default_agent_id` | 跟随系统默认 agent（`router.default_agent_id`，系统层也为空才回落名字序第一个 active agent） |
/// | `display_name` | 未设置，展示侧回落 `users.name` → `email` |
/// | `avatar_url` | 未设置，渲染内置图标 |
///
/// `reply_language` 是唯一的例外：它**恒有值**（未设置时服务端下发 `"auto"`），
/// 故客户端无需区分「字段缺失」与「默认」。
///
/// `habit_notify_channels` 另有哨兵：空串 = 未设置（回退「最近入站渠道」），
/// `"off"` = **显式关闭**。两者语义相反，故必须配合
/// [habitNotifyChannelsSet] 区分——见该字段文档。
library;

/// 语言标签 `auto`（「跟随输入语言」）。
///
/// 真源：Go `internal/userpref/userpref.go` 的 `LangAuto`。
const String kLanguageAuto = 'auto';

/// 习惯推送渠道的「显式关闭」哨兵值。
///
/// 真源：Go `internal/outboundchannel` 的 `Off`。与空串（未设置）语义相反。
const String kHabitNotifyOff = 'off';

/// `available_channels` 的一项。
///
/// ## 为什么 label 必须由服务端下发
///
/// 允许用户选一个他没绑定的渠道 = 保证推送失败，故选项必须从**该用户实际绑定**
/// 派生；而渠道白名单的真源在 mq-server（跨仓），客户端硬编码必然漂移。
/// 同理中文展示名（微信 / 企业微信 / 飞书 / 钉钉）也由服务端下发
/// （Go `outboundchannel.Label`）——三端各写一份必然不一致，而「微信」指个人微信
/// （iLink 桥接）、「企业微信」是另一个产品，叫法混淆会导致用户选错渠道。
class PreferenceChannelOption {
  const PreferenceChannelOption({required this.value, required this.label});

  /// 渠道标识（`wechat_ilink` / `wecom` / `feishu` / `dingtalk`）。
  final String value;

  /// 中文展示名（**直接渲染，不自算**）。
  final String label;

  factory PreferenceChannelOption.fromJson(Map<String, dynamic> json) =>
      PreferenceChannelOption(
        value: (json['value'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
      );

  @override
  String toString() => 'PreferenceChannelOption($value, $label)';
}

/// 用户偏好。
class UserPreferences {
  const UserPreferences({
    this.replyLanguage = kLanguageAuto,
    this.availableLanguages = const [],
    this.languageLabels = const {},
    this.customized = false,
    this.followUpSuggest = false,
    this.habitSuggest = false,
    this.defaultAgentId = '',
    this.displayName = '',
    this.avatarUrl = '',
    this.habitNotifyChannels = '',
    this.habitNotifyChannelsSet = false,
    this.availableChannels = const [],
    this.raw = const {},
  });

  /// 回复语言标签（`auto` / `zh-CN` / `en` / `ja`）。**恒有值**。
  final String replyLanguage;

  /// 服务端支持的语言标签（有序，供下拉渲染）。
  ///
  /// 服务端新增语言时前端**无需改动**：遍历本列表 + 用 [languageLabel] 取展示名。
  final List<String> availableLanguages;

  /// 语言标签 → 展示名（如 `zh-CN` → 「简体中文」、`auto` → 「跟随输入」）。
  final Map<String, String> languageLabels;

  /// 是否被用户显式设置过回复语言（用于展示「已自定义 / 恢复默认」）。
  final bool customized;

  /// 新建 group 是否默认开启「后续提问建议」。
  ///
  /// 仅影响**之后新建**的 group（建组时播种），不回溯修改既有 group。
  final bool followUpSuggest;

  /// 新建 group 是否默认开启「习惯建议」（`habit_suggest`）。
  ///
  /// 与 [followUpSuggest] 完全同构：仅影响之后新建的 group（建组时播种到
  /// `metadata.habit_suggest`），不回溯修改既有 group。实际生效还受 env
  /// `HABIT_SUGGEST_ENABLED` 全局闸约束（能力总闸，本项只表达用户意愿）。
  ///
  /// ⚠️ 与群级同名开关（[ChatGroup.habitSuggestEnabled]）是**不同层次**：本处是
  /// 「以后新建对话的默认值」，那个是「这个对话现在开不开」。
  final bool habitSuggest;

  /// 用户默认 agent（chat_router 兜底值）。空串 = 跟随系统默认。
  final String defaultAgentId;

  /// 自设展示昵称。空串 = 未设置。
  final String displayName;

  /// 自设头像地址。空串 = 未设置。
  ///
  /// 服务端下发前**不做 URL 校验**（校验在展示层，否则用户存了非法值会看到
  /// 「保存成功但值不见了」）。故渲染前必须自行 sanitize。
  final String avatarUrl;

  /// 习惯结果推送渠道（**逗号分隔原样下发**，便于输入框直接回填编辑）。
  ///
  /// 空串 = 未设置；[kHabitNotifyOff] = 显式关闭；否则为逗号分隔列表。
  final String habitNotifyChannels;

  /// 区分「未设置」与「配了但已失效 / 显式关闭」。
  ///
  /// ## 为什么不能只看 [habitNotifyChannels]
  ///
  /// 若只回值，客户端无法区分：
  /// - **未设置** → 应显示默认选中项；
  /// - **配了但渠道已全部解绑** → 应显示「你选的渠道已失效」。
  ///
  /// 两者都表现为某个值/空值，但语义相反。
  final bool habitNotifyChannelsSet;

  /// 该用户**当前可推送**的渠道选项（由服务端从实际绑定派生）。
  final List<PreferenceChannelOption> availableChannels;

  /// 原始响应，供将来新增字段时不必改模型即可读取。
  final Map<String, dynamic> raw;

  // ---------- 语义 getter ----------

  /// 回复语言是否为「跟随输入」（未自定义）。
  ///
  /// 空串也算：服务端写入侧把 `auto` 与空串同构处理（都删记录），历史脏数据里
  /// 可能出现空串。
  bool get isReplyLanguageAuto =>
      replyLanguage.isEmpty || replyLanguage == kLanguageAuto;

  /// 是否设置了自定义昵称（未设置时展示侧回落 `users.name` → `email`）。
  bool get hasCustomDisplayName => displayName.isNotEmpty;

  /// 是否设置了自定义头像。
  bool get hasCustomAvatar => avatarUrl.isNotEmpty;

  /// 默认 agent 是否为「自动」（跟随系统默认）。
  bool get defaultAgentIsAuto => defaultAgentId.isEmpty;

  /// 是否**显式关闭**了习惯推送（与「未设置」相反）。
  bool get habitNotifyDisabled =>
      habitNotifyChannelsSet &&
      (habitNotifyChannels.isEmpty || habitNotifyChannels == kHabitNotifyOff);

  /// 已选的习惯推送渠道（逗号分隔 → 列表，已 trim、去空）。
  ///
  /// 显式关闭时返回空列表。
  List<String> get selectedHabitChannels {
    if (!habitNotifyChannelsSet) return const [];
    final value = habitNotifyChannels.trim();
    if (value.isEmpty || value == kHabitNotifyOff) return const [];
    return value
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 取语言标签的展示名；缺键时回落原始标签。
  ///
  /// 回落而非返回空串：显示空白会让人以为「这个选项坏了」。
  String languageLabel(String tag) {
    final label = languageLabels[tag];
    return (label == null || label.isEmpty) ? tag : label;
  }

  factory UserPreferences.fromJson(Map<String, dynamic> json) =>
      UserPreferences(
        replyLanguage: (json['reply_language'] ?? kLanguageAuto).toString(),
        availableLanguages: _stringList(json['available_languages']),
        languageLabels: _stringMap(json['language_labels']),
        customized: json['customized'] == true,
        followUpSuggest: json['follow_up_suggest'] == true,
        habitSuggest: json['habit_suggest'] == true,
        defaultAgentId: (json['default_agent_id'] ?? '').toString(),
        displayName: (json['display_name'] ?? '').toString(),
        avatarUrl: (json['avatar_url'] ?? '').toString(),
        habitNotifyChannels: (json['habit_notify_channels'] ?? '').toString(),
        habitNotifyChannelsSet: json['habit_notify_channels_set'] == true,
        availableChannels: _channels(json['available_channels']),
        raw: json,
      );

  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }

  static Map<String, String> _stringMap(Object? v) {
    if (v is! Map) return const {};
    final out = <String, String>{};
    v.forEach((k, value) {
      if (value == null) return;
      out[k.toString()] = value.toString();
    });
    return out;
  }

  static List<PreferenceChannelOption> _channels(Object? v) {
    if (v is! List) return const [];
    final out = <PreferenceChannelOption>[];
    for (final e in v) {
      if (e is Map) {
        out.add(PreferenceChannelOption.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return out;
  }

  @override
  String toString() =>
      'UserPreferences(replyLanguage=$replyLanguage, customized=$customized, '
      'defaultAgentId=$defaultAgentId)';
}

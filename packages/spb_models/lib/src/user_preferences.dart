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
    this.followUpSuggestAvailable = true,
    this.habitSuggest = false,
    this.habitSuggestAvailable = true,
    this.agentRecommend = true,
    this.agentRecommendSet = false,
    this.agentRecommendAvailable = true,
    this.goalJudge = false,
    this.goalJudgeAvailable = true,
    this.goalDiscovery = false,
    this.goalDiscoveryAvailable = true,
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

  /// 是否给执行 agent 注入「后续提问建议约定」（follow_up_suggest reminder：
  /// agent 在实质回复后附 3~5 条可点击追问）。
  ///
  /// ⚠️ 语义已变更（2026-11，随 Go `452cc432`）：这是**运行时开关**——对所有
  /// 会话生效，改完下一轮生效。不再是「新建 group 的默认播种值」：group 级
  /// `metadata.follow_up_suggest`、专用端点 `PUT /chat/groups/:id/follow-up-suggest`
  /// 与建组播种均已移除。缺省关（未表态 / 读失败）。
  ///
  /// 实际可用性还受运维急停 `FOLLOW_UP_SUGGEST_DISABLED` 约束（急停中开关能拨
  /// 但不会有建议），见 [followUpSuggestAvailable]。
  final bool followUpSuggest;

  /// 「后续提问建议」能力当前是否可用（运维急停 `FOLLOW_UP_SUGGEST_DISABLED`
  /// 时为 false）。
  ///
  /// 与 [UserPreferences.habitNotifyChannelsSet] 同一取向：开关能拨但服务端已
  /// 停用时，若不下发这个字段，用户会以为是自己没配好而反复排查——真因只有
  /// 运维知道。面板据此置灰并说明原因。缺省 true（响应缺失时按可用处理，
  /// 把加载中也显示成「已停用」会让每次打开面板都闪一次误导性提示）。
  final bool followUpSuggestAvailable;

  /// 是否给执行 agent 注入「习惯建议约定」（habit_suggest reminder）。
  ///
  /// ⚠️ 语义已变更（2026-11，随 Go `47e9950e`）：这是**运行时开关**（对所有
  /// 会话生效），不再是「新建 group 的默认播种值」：group 级
  /// `metadata.habit_suggest`、专用端点 `PUT /chat/groups/:id/habit-suggest`
  /// 与建组播种均已移除。缺省关（未表态 / 读失败），与 [agentRecommend] 的
  /// 缺省开相反。
  ///
  /// 开关为开**不等于**每轮都注入：服务端注入前还有意图判定链（先 Jev，无效
  /// 时降级 LLM 单字符判断），确认本轮输入含周期性意图才注入。面板文案必须
  /// 说清，否则用户会把「没收到建议」当成开关失效。
  final bool habitSuggest;

  /// 「习惯建议」能力当前是否可用（运维急停 `HABIT_SUGGEST_DISABLED` 时为
  /// false）。语义同 [followUpSuggestAvailable]。
  final bool habitSuggestAvailable;

  /// 是否接收「本轮可能更适合别的 Agent」提示（agent_recommend reminder）。
  ///
  /// **准入就是本项**（2026-11，随 Go `1bdbc38c`）：不再有 env 准入总闸
  /// （原 `AGENT_RECOMMEND_ENABLED` 已废），用户勾上即真正生效。唯一的非用户
  /// 控制是运维急停 `AGENT_RECOMMEND_DISABLED`，其效果由 [agentRecommendAvailable]
  /// 下发（**不改写**本项——急停不该把所有人的开关抹成关）。
  ///
  /// 缺省**开**：未表态时服务端下发 true（与执行侧解析同源）。与
  /// [followUpSuggest] / [habitSuggest] 的缺省关方向相反，勿照抄。
  final bool agentRecommend;

  /// 区分「未表态（默认开）」与「用户显式设置过」。
  ///
  /// 必须单独下发：本项缺省为**开**，只看 [agentRecommend] 的值无法区分
  /// 「我从未表态（默认开）」与「我明确打开了」——前者应展示「默认开启」，
  /// 后者应展示「你已开启」。与 [habitNotifyChannelsSet] 同因。
  final bool agentRecommendSet;

  /// 「Agent 建议」能力当前是否可用（运维急停 `AGENT_RECOMMEND_DISABLED` 时
  /// 为 false）。语义同 [followUpSuggestAvailable]。
  final bool agentRecommendAvailable;

  /// 是否对「目标约定」做相关性判定（goal_judge）。
  ///
  /// 运行时开关（2026-11，随 Go `7a814ed6`，与 habit_suggest 同构）：开启后，
  /// 用户手动消息会先问一次 Jev「这句是否与当前目标的推进相关」，高置信无关
  /// 才不注入约定。只对已开 goal gate 的群有可感效果（没开 gate 就没有目标
  /// 约定可注入）。
  ///
  /// 缺省关：判定在首 token 前付一次 Jev（p50≈1.2s），不该由平台默认替用户
  /// 按下。goal gate 续跑 / 规划轮恒注入，不受本项影响。
  final bool goalJudge;

  /// 「目标判定」能力当前是否可用（运维急停 `GOAL_JUDGE_DISABLED` 时为
  /// false）。语义同 [followUpSuggestAvailable]。
  final bool goalJudgeAvailable;

  /// 是否允许执行 agent 在对话中发现候选目标并提议建立（goal_discovery）。
  ///
  /// 运行时开关（2026-11，随 Go `040855fe`，与 goal_judge 同构）：开启后，
  /// 对话尚无生效目标时，执行 agent 会收到一段「目标发现约定」——输入确实
  /// 表达了值得跨轮推进的目标时，**先向用户提议**（建 goal + 开自动推进），
  /// 用户确认后才动手。本开关是准入不是授权：自动实现仍由 group 级
  /// goal_gate.enabled 控制。
  ///
  /// 缺省关（未设置 / 读失败 / 脏值一律 false）：误发现的代价是 agent 建错
  /// goal 并可能在确认链意外放行时开始自动推进（烧掉数轮 token）——宁可漏
  /// 发现不可误发现，方向与 [habitSuggest] 同向、与 [agentRecommend] 相反。
  ///
  /// ⚠️ 上游缺口（2026-11-04，Gitea issue super_partyb#95）：服务端 PUT 已接受
  /// 本键，但 GET 响应尚**未下发** `goal_discovery` / `goal_discovery_available`。
  /// 在上游补齐之前，本字段解析恒为缺省值（false / true）——保存成功但
  /// 回读显示关，与 webapp 面板的现状一致，不是本包的解析缺陷。
  final bool goalDiscovery;

  /// 「目标发现」能力当前是否可用（运维急停 `GOAL_DISCOVERY_DISABLED` 时为
  /// false）。语义同 [followUpSuggestAvailable]。同样受上游 #95 影响
  /// （GET 未下发前恒为 true）。
  final bool goalDiscoveryAvailable;

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
        followUpSuggestAvailable: json['follow_up_suggest_available'] != false,
        habitSuggest: json['habit_suggest'] == true,
        habitSuggestAvailable: json['habit_suggest_available'] != false,
        agentRecommend: json['agent_recommend'] != false,
        agentRecommendSet: json['agent_recommend_set'] == true,
        agentRecommendAvailable: json['agent_recommend_available'] != false,
        goalJudge: json['goal_judge'] == true,
        goalJudgeAvailable: json['goal_judge_available'] != false,
        // 缺省关（与 goal_judge 同向）。⚠️ 上游 #95：GET 未下发前恒为缺省。
        goalDiscovery: json['goal_discovery'] == true,
        goalDiscoveryAvailable: json['goal_discovery_available'] != false,
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
      'defaultAgentId=$defaultAgentId, followUp=$followUpSuggest, '
      'habit=$habitSuggest, agentRecommend=$agentRecommend, '
      'goalJudge=$goalJudge, goalDiscovery=$goalDiscovery)';
}

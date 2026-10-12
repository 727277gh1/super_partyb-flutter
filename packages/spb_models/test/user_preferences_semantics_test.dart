import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `UserPreferences` 的语义 getter 与嵌套解析测试（补 `user_preferences_test.dart`
/// 未覆盖的部分）。
///
/// ## 已有的 `user_preferences_test.dart` 覆盖什么
///
/// 它只钉 `follow_up_suggest` / `habit_suggest` 两个**默认值开关**。本文件补：
///
/// - 三个「空串是合法状态」的 getter（`isReplyLanguageAuto` / `hasCustomDisplayName`
///   / `hasCustomAvatar` / `defaultAgentIsAuto`）；
/// - **习惯推送渠道的三态**（未设置 / 显式关闭 / 已选列表）——这是最容易读错的
///   地方：空串与 `off` 语义相反，必须配合 `habit_notify_channels_set` 区分；
/// - 嵌套的 `available_channels`（含 label 由服务端下发）与 `language_labels`；
/// - `languageLabel` 的**回落**（缺键时返回原始 tag，不返回空串）。
void main() {
  Map<String, dynamic> prefsJson({
    String replyLanguage = 'auto',
    Object? customized,
    String defaultAgentId = '',
    String displayName = '',
    String avatarUrl = '',
    String habitNotifyChannels = '',
    Object? habitNotifyChannelsSet,
    Object? availableLanguages,
    Object? languageLabels,
    Object? availableChannels,
  }) => {
    'reply_language': replyLanguage,
    if (customized != null) 'customized': customized,
    'default_agent_id': defaultAgentId,
    'display_name': displayName,
    'avatar_url': avatarUrl,
    'habit_notify_channels': habitNotifyChannels,
    if (habitNotifyChannelsSet != null)
      'habit_notify_channels_set': habitNotifyChannelsSet,
    if (availableLanguages != null) 'available_languages': availableLanguages,
    if (languageLabels != null) 'language_labels': languageLabels,
    if (availableChannels != null) 'available_channels': availableChannels,
  };

  group('回复语言：isReplyLanguageAuto（空串也算 auto）', () {
    test('空串与 auto 都判 auto（服务端把两者同构处理）', () {
      // 服务端写入侧把 auto 与空串都「删记录」，历史脏数据里可能出现空串。
      expect(
        UserPreferences.fromJson(prefsJson(replyLanguage: ''))
            .isReplyLanguageAuto,
        isTrue,
      );
      expect(
        UserPreferences.fromJson(prefsJson(replyLanguage: 'auto'))
            .isReplyLanguageAuto,
        isTrue,
      );
    });

    test('具体语言不判 auto', () {
      for (final lang in ['zh-CN', 'en', 'ja']) {
        expect(
          UserPreferences.fromJson(prefsJson(replyLanguage: lang))
              .isReplyLanguageAuto,
          isFalse,
        );
      }
    });
  });

  group('三个「空串 = 未设置」的 getter', () {
    test('hasCustomDisplayName / hasCustomAvatar / defaultAgentIsAuto', () {
      final empty = UserPreferences.fromJson(prefsJson());
      expect(empty.hasCustomDisplayName, isFalse);
      expect(empty.hasCustomAvatar, isFalse);
      expect(empty.defaultAgentIsAuto, isTrue);

      final set = UserPreferences.fromJson(
        prefsJson(
          displayName: '小明',
          avatarUrl: 'http://x/a.png',
          defaultAgentId: 'agt_1',
        ),
      );
      expect(set.hasCustomDisplayName, isTrue);
      expect(set.hasCustomAvatar, isTrue);
      expect(set.defaultAgentIsAuto, isFalse);
    });
  });

  group('习惯推送渠道三态（空串 ≠ off）', () {
    test('未设置：channelsSet=false，disabled=false，selected 为空', () {
      final p = UserPreferences.fromJson(prefsJson());
      expect(p.habitNotifyChannelsSet, isFalse);
      // 未设置**不是**「显式关闭」——界面应显示默认选中项，而非「已关闭」。
      expect(p.habitNotifyDisabled, isFalse);
      expect(p.selectedHabitChannels, isEmpty);
    });

    test('显式关闭：channelsSet=true + off → disabled=true', () {
      final p = UserPreferences.fromJson(
        prefsJson(habitNotifyChannels: 'off', habitNotifyChannelsSet: true),
      );
      expect(p.habitNotifyChannelsSet, isTrue);
      expect(p.habitNotifyDisabled, isTrue);
      expect(p.selectedHabitChannels, isEmpty);
    });

    test('channelsSet=true + 空串也算关闭（渠道全解绑）', () {
      // 配了但渠道已全部失效，与显式关闭在「不该推」上等价。
      final p = UserPreferences.fromJson(
        prefsJson(habitNotifyChannels: '', habitNotifyChannelsSet: true),
      );
      expect(p.habitNotifyDisabled, isTrue);
      expect(p.selectedHabitChannels, isEmpty);
    });

    test('已选列表：逗号分隔 → trim + 去空', () {
      final p = UserPreferences.fromJson(
        prefsJson(
          habitNotifyChannels: ' wechat_ilink , wecom ,, feishu ',
          habitNotifyChannelsSet: true,
        ),
      );
      expect(p.selectedHabitChannels, ['wechat_ilink', 'wecom', 'feishu']);
      expect(p.habitNotifyDisabled, isFalse);
    });

    test('channelsSet=false 时即便有值也不解析（未设置优先）', () {
      final p = UserPreferences.fromJson(
        prefsJson(habitNotifyChannels: 'wecom', habitNotifyChannelsSet: false),
      );
      expect(p.selectedHabitChannels, isEmpty);
    });
  });

  group('languageLabel：缺键回落原始 tag（不返回空串）', () {
    test('有标签用标签，无标签/空标签回落 tag', () {
      final p = UserPreferences.fromJson(
        prefsJson(
          languageLabels: {'auto': '跟随输入', 'en': 'English', 'zh-CN': ''},
        ),
      );
      expect(p.languageLabel('auto'), '跟随输入');
      expect(p.languageLabel('en'), 'English');
      // 空标签回落 tag——显示空白会让人以为「这个选项坏了」。
      expect(p.languageLabel('zh-CN'), 'zh-CN');
      expect(p.languageLabel('ja'), 'ja');
    });
  });

  group('嵌套列表 / 映射解析', () {
    test('available_languages 过滤空串', () {
      final p = UserPreferences.fromJson(
        prefsJson(availableLanguages: ['auto', '', 'en']),
      );
      expect(p.availableLanguages, ['auto', 'en']);
    });

    test('language_labels 非字符串值转成字符串，null 值跳过', () {
      final p = UserPreferences.fromJson(
        prefsJson(languageLabels: {'a': 1, 'b': null, 'c': 'C'}),
      );
      expect(p.languageLabels['a'], '1');
      expect(p.languageLabels.containsKey('b'), isFalse);
      expect(p.languageLabels['c'], 'C');
    });

    test('available_channels 解析出 value/label（label 由服务端下发）', () {
      final p = UserPreferences.fromJson(
        prefsJson(
          availableChannels: [
            {'value': 'wechat_ilink', 'label': '微信'},
            {'value': 'wecom', 'label': '企业微信'},
            'garbage',
            {'value': 'feishu'}, // label 缺失 → 空串
          ],
        ),
      );
      expect(p.availableChannels, hasLength(3));
      expect(p.availableChannels[0].value, 'wechat_ilink');
      expect(p.availableChannels[0].label, '微信');
      expect(p.availableChannels[2].value, 'feishu');
      expect(p.availableChannels[2].label, '');
    });

    test('非列表 / 缺失 → 空列表（不抛）', () {
      final p = UserPreferences.fromJson(
        prefsJson(availableChannels: 'x', availableLanguages: 'y'),
      );
      expect(p.availableChannels, isEmpty);
      expect(p.availableLanguages, isEmpty);
    });
  });

  group('customized 只认严格 true', () {
    test('true / false / 缺失 / 脏值', () {
      expect(
        UserPreferences.fromJson(prefsJson(customized: true)).customized,
        isTrue,
      );
      expect(
        UserPreferences.fromJson(prefsJson(customized: false)).customized,
        isFalse,
      );
      expect(UserPreferences.fromJson(prefsJson()).customized, isFalse);
      expect(
        UserPreferences.fromJson(prefsJson(customized: 'true')).customized,
        isFalse,
      );
    });
  });

  group('PreferenceChannelOption.fromJson', () {
    test('字段解析与缺字段回落', () {
      final o = PreferenceChannelOption.fromJson(const {
        'value': 'dingtalk',
        'label': '钉钉',
      });
      expect(o.value, 'dingtalk');
      expect(o.label, '钉钉');

      final empty = PreferenceChannelOption.fromJson(const {});
      expect(empty.value, '');
      expect(empty.label, '');
    });
  });
}

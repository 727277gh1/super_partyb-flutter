import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `UserPreferences` 契约解析测试。
///
/// ## 这个测试防的是什么
///
/// `UserPreferences` 是 `GET /me/preferences` 的**部分字段**契约：服务端只返回
/// 已显式设置的项（`reply_language` 除外，它恒有值），其余键**直接缺席**。
/// 解析时读错键名或把「缺失」当 `true` 都不会报错，只会让开关静默显示错值。
///
/// 尤其钉住两个**新建 group 的默认值**：
///
/// | 键 | 语义 |
/// |---|---|
/// | `follow_up_suggest` | 新建 group 默认开「后续提问建议」 |
/// | `habit_suggest` | 新建 group 默认开「习惯建议」 |
///
/// 两者与群级同名开关是**不同层次**：本处是「以后新建的默认」，群级那个是
/// 「这个对话现在开不开」。混用会让用户改了「默认」却发现老对话没变。
void main() {
  /// 服务端 `userPrefResponse` 的真实形状（`internal/server/user_preferences.go`）。
  Map<String, dynamic> prefsJson({
    bool? followUpSuggest,
    bool? habitSuggest,
    String replyLanguage = 'en',
  }) => {
    'reply_language': replyLanguage,
    'available_languages': ['auto', 'zh-CN', 'en', 'ja'],
    'language_labels': {'auto': '跟随输入', 'en': 'English'},
    'customized': true,
    if (followUpSuggest != null) 'follow_up_suggest': followUpSuggest,
    if (habitSuggest != null) 'habit_suggest': habitSuggest,
    'default_agent_id': '',
    'display_name': '',
    'avatar_url': '',
    'habit_notify_channels': '',
    'habit_notify_channels_set': false,
    'available_channels': <dynamic>[],
  };

  group('habit_suggest 解析', () {
    test('true → habitSuggest 为 true', () {
      final p = UserPreferences.fromJson(prefsJson(habitSuggest: true));

      expect(p.habitSuggest, isTrue);
    });

    test('false → habitSuggest 为 false', () {
      final p = UserPreferences.fromJson(prefsJson(habitSuggest: false));

      expect(p.habitSuggest, isFalse);
    });

    test('键缺失 → 回落 false（不是 null/抛异常）', () {
      // 服务端只返回显式设置过的项，故「缺失」是最常见的形态。
      // 若解析写成 `json['habit_suggest'] as bool` 会直接抛。
      final p = UserPreferences.fromJson(prefsJson());

      expect(p.habitSuggest, isFalse);
    });

    test('非 bool 脏值不误判为 true', () {
      // 手工改过库 / 旧版本客户端写入的值都可能出现。
      final p = UserPreferences.fromJson(
        prefsJson()..['habit_suggest'] = 'true',
      );

      expect(p.habitSuggest, isFalse);
    });
  });

  group('follow_up_suggest 解析', () {
    test('true → followUpSuggest 为 true', () {
      final p = UserPreferences.fromJson(prefsJson(followUpSuggest: true));

      expect(p.followUpSuggest, isTrue);
    });

    test('键缺失 → 回落 false', () {
      final p = UserPreferences.fromJson(prefsJson());

      expect(p.followUpSuggest, isFalse);
    });
  });

  group('两个默认值互不影响', () {
    test('只开 habit_suggest 时 followUpSuggest 仍为 false', () {
      // 两个键若被解析成同一个字段（复制粘贴时的典型错误），这条会挂。
      final p = UserPreferences.fromJson(prefsJson(habitSuggest: true));

      expect(p.habitSuggest, isTrue);
      expect(p.followUpSuggest, isFalse);
    });

    test('只开 follow_up_suggest 时 habitSuggest 仍为 false', () {
      final p = UserPreferences.fromJson(prefsJson(followUpSuggest: true));

      expect(p.followUpSuggest, isTrue);
      expect(p.habitSuggest, isFalse);
    });
  });
}

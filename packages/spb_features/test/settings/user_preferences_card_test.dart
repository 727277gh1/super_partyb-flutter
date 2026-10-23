import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 用户偏好卡片的 widget 测试。
///
/// ## 这个测试防的是什么
///
/// 偏好卡片的失败模式几乎都**静默**，而且后果是「用户以为改好了，其实没有」：
/// - **提交全部字段** → 另一台设备刚改的回复语言被本端一次「保存」盖回去；
/// - **硬编码语言列表** → 后端新增语言必须改客户端并发版（小程序还得重新提审）；
/// - **空 `default_agent_id` 渲染成空白项** → 用户看到空下拉，以为设置坏了；
/// - **非法头像地址静默丢弃** → 「保存成功但头像没变」，用户反复重试；
/// - **加载失败时渲染空表单** → 看起来像「你的偏好是空的」，用户可能就此
///   覆盖掉真实值。
///
/// 故逐条断言：只提交改动字段、选项来自注入列表、空串有文案、非法地址阻止
/// 保存并给出改法、加载失败整块退化为重试入口。
void main() {
  /// 默认的两个可推送渠道选项（服务端 `available_channels` 的真实形状）。
  const kDefaultChannels = [
    PreferenceChannelOption(value: 'wechat_ilink', label: '微信'),
    PreferenceChannelOption(value: 'dingtalk', label: '钉钉'),
  ];

  /// 服务端 `userPrefResponse` 的典型形状。
  UserPreferences prefs({
    String replyLanguage = 'en',
    bool customized = true,
    bool followUpSuggest = false,
    bool habitSuggest = false,
    String defaultAgentId = '',
    String displayName = '',
    String avatarUrl = '',
    String habitNotifyChannels = '',
    bool habitNotifyChannelsSet = false,
    List<PreferenceChannelOption>? availableChannels,
    List<String>? availableLanguages,
    Map<String, String>? languageLabels,
  }) => UserPreferences(
    replyLanguage: replyLanguage,
    availableLanguages:
        availableLanguages ?? const ['auto', 'zh-CN', 'en', 'ja'],
    languageLabels:
        languageLabels ??
        const {'auto': '跟随输入', 'zh-CN': '简体中文', 'en': 'English', 'ja': '日本語'},
    customized: customized,
    followUpSuggest: followUpSuggest,
    habitSuggest: habitSuggest,
    defaultAgentId: defaultAgentId,
    displayName: displayName,
    avatarUrl: avatarUrl,
    habitNotifyChannels: habitNotifyChannels,
    habitNotifyChannelsSet: habitNotifyChannelsSet,
    availableChannels: availableChannels ?? kDefaultChannels,
  );

  /// 一次 save 调用捕获到的参数。
  late ({
    String? displayName,
    String? avatarUrl,
    String? replyLanguage,
    String? defaultAgentId,
    bool? followUpSuggest,
    bool? habitSuggest,
    String? habitNotifyChannels,
  })?
  lastSave;

  /// save 的调用次数（验证「未改动不发请求」）。
  late int saveCalls;

  /// 把卡片放进最小可用的 MaterialApp。
  ///
  /// 窗口调高：卡片含 4 个表单项 + 保存行，默认 800×600 会让底部条目落在
  /// 屏幕外（`ListView`/`Column` 里的内容虽会构建，但 `tap` 会因坐标在窗口外
  /// 而报 "would not hit test"）。
  Future<void> pumpCard(
    WidgetTester tester, {
    UserPreferences? loaded,
    List<PreferenceAgentOption> agentOptions = const [],
    String fallbackDisplayName = '',
    Object? loadError,
    Object? saveError,
    UserPreferences Function()? saveResult,
  }) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    lastSave = null;
    saveCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: UserPreferencesCard(
              load: () async {
                if (loadError != null) throw loadError;
                return loaded ?? prefs();
              },
              save:
                  ({
                    String? displayName,
                    String? avatarUrl,
                    String? replyLanguage,
                    String? defaultAgentId,
                    bool? followUpSuggest,
                    bool? habitSuggest,
                    String? habitNotifyChannels,
                  }) async {
                    saveCalls++;
                    lastSave = (
                      displayName: displayName,
                      avatarUrl: avatarUrl,
                      replyLanguage: replyLanguage,
                      defaultAgentId: defaultAgentId,
                      followUpSuggest: followUpSuggest,
                      habitSuggest: habitSuggest,
                      habitNotifyChannels: habitNotifyChannels,
                    );
                    if (saveError != null) throw saveError;
                    return saveResult?.call() ?? prefs();
                  },
              agentOptions: agentOptions,
              fallbackDisplayName: fallbackDisplayName,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 展开下拉并选中某一项。
  ///
  /// `find.text(label).last`：选中值同时出现在「按钮」与「菜单项」里，
  /// 取 last 才是弹出菜单里那一份。
  Future<void> pickDropdown(WidgetTester tester, Key key, String label) async {
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  group('回复语言：选项来自注入列表，不硬编码', () {
    testWidgets('渲染服务端下发的语言与展示名', (tester) async {
      await pumpCard(tester, loaded: prefs());

      await tester.tap(
        find.byKey(const ValueKey('settings-prefs-reply-language')),
      );
      await tester.pumpAndSettle();

      expect(find.text('简体中文'), findsWidgets);
      expect(find.text('日本語'), findsWidgets);
      // 「跟随输入」是 auto 的展示名（服务端 language_labels 下发）。
      expect(find.text('跟随输入'), findsWidgets);
    });

    testWidgets('后端新增语言时客户端无需改代码（选项来自响应）', (tester) async {
      // 回归防线：若客户端硬编码 ['auto','zh-CN','en','ja']，本用例会失败。
      await pumpCard(
        tester,
        loaded: prefs(
          availableLanguages: const ['auto', 'fr'],
          languageLabels: const {'auto': '跟随输入', 'fr': 'Français'},
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('settings-prefs-reply-language')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Français'), findsWidgets, reason: '新语言应直接可选');
      expect(
        find.text('简体中文'),
        findsNothing,
        reason: '响应里没有的语言不该出现（说明选项不是硬编码的）',
      );
    });

    testWidgets('缺 label 时回退原始标签，不显示空白', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(
          availableLanguages: const ['auto', 'fr'],
          languageLabels: const {'auto': '跟随输入'},
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('settings-prefs-reply-language')),
      );
      await tester.pumpAndSettle();

      expect(find.text('fr'), findsWidgets, reason: '显示空白会让用户以为选项坏了');
    });

    testWidgets('available_languages 为空时仍有一个可用选项（不崩）', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(availableLanguages: const [], languageLabels: const {}),
      );

      expect(
        find.byKey(const ValueKey('settings-prefs-reply-language')),
        findsOneWidget,
      );
    });
  });

  group('默认 Agent：空串必须渲染成「自动」', () {
    testWidgets('空 default_agent_id 显示「自动（跟随系统默认）」', (tester) async {
      await pumpCard(tester, loaded: prefs(defaultAgentId: ''));

      expect(
        find.text('自动（跟随系统默认）'),
        findsOneWidget,
        reason: '渲染成空白项会让用户以为设置坏了',
      );
    });

    testWidgets('有 agent 列表时渲染各 agent 名', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(defaultAgentId: 'a2'),
        agentOptions: const [
          PreferenceAgentOption(id: 'a1', name: '写作助手'),
          PreferenceAgentOption(id: 'a2', name: '代码助手'),
        ],
      );

      await tester.tap(
        find.byKey(const ValueKey('settings-prefs-default-agent')),
      );
      await tester.pumpAndSettle();

      expect(find.text('写作助手'), findsWidgets);
      expect(find.text('代码助手'), findsWidgets);
      expect(find.text('自动（跟随系统默认）'), findsWidgets);
    });

    testWidgets('agent 名为空时回退 id（不显示空白项）', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(defaultAgentId: ''),
        agentOptions: const [PreferenceAgentOption(id: 'a1', name: '')],
      );

      await tester.tap(
        find.byKey(const ValueKey('settings-prefs-default-agent')),
      );
      await tester.pumpAndSettle();

      expect(find.text('a1'), findsWidgets);
    });

    testWidgets('已选 agent 不在列表里时补一条「已失效」（不抛断言）', (tester) async {
      // agent 被归档/删除后，偏好里的 id 仍指向它，而列表只含 active。
      // 若把它塞进 DropdownButton 而 items 里没有，Flutter 会直接抛断言。
      await pumpCard(
        tester,
        loaded: prefs(defaultAgentId: 'a_gone'),
        agentOptions: const [PreferenceAgentOption(id: 'a1', name: '写作助手')],
      );

      expect(find.text('a1（已失效）'.replaceFirst('a1', 'a_gone')), findsOneWidget);
    });
  });

  group('保存：只提交改动过的字段', () {
    testWidgets('未改动时不显示保存按钮、不发请求', (tester) async {
      await pumpCard(tester, loaded: prefs(displayName: '张三'));

      expect(
        find.byKey(const ValueKey('settings-prefs-save')),
        findsNothing,
        reason: '无改动时不该出现保存入口',
      );
      expect(saveCalls, 0);
    });

    testWidgets('只改昵称 → 其它三个字段传 null（部分更新语义）', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(replyLanguage: 'en', displayName: '张三'),
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '李四',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(saveCalls, 1);
      expect(lastSave!.displayName, '李四');
      expect(lastSave!.replyLanguage, isNull, reason: '提交全部字段会把另一台设备刚改的值盖回去');
      expect(lastSave!.avatarUrl, isNull);
      expect(lastSave!.defaultAgentId, isNull);
    });

    testWidgets('只改回复语言 → 只提交 reply_language', (tester) async {
      await pumpCard(tester, loaded: prefs(replyLanguage: 'en'));

      await pickDropdown(
        tester,
        const ValueKey('settings-prefs-reply-language'),
        '日本語',
      );
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.replyLanguage, 'ja');
      expect(lastSave!.displayName, isNull);
    });

    testWidgets('选「自动」提交空串（不是 null，也不是 "auto"）', (tester) async {
      await pumpCard(tester, loaded: prefs(defaultAgentId: 'a1'));

      await pickDropdown(
        tester,
        const ValueKey('settings-prefs-default-agent'),
        '自动（跟随系统默认）',
      );
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(
        lastSave!.defaultAgentId,
        '',
        reason: '空串是「恢复跟随系统默认」，null 是「不改」——两者不同',
      );
    });

    testWidgets('昵称清空提交空串（清除自设昵称）', (tester) async {
      await pumpCard(tester, loaded: prefs(displayName: '张三'));

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.displayName, '');
    });

    testWidgets('改动后保存成功用服务端返回值覆盖本地', (tester) async {
      // 服务端会归一化（如 auto 被转成「删记录」），本地乐观值可能与事实不符。
      await pumpCard(
        tester,
        loaded: prefs(displayName: '张三'),
        saveResult: () => prefs(displayName: '李四', customized: false),
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '李四',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-prefs-saved')),
        findsOneWidget,
      );
      // 保存行仍在（为了展示「已保存」反馈），但按钮已禁用：草稿与基线一致。
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('settings-prefs-save')),
      );
      expect(button.onPressed, isNull, reason: '保存后不应再有未保存改动');
    });
  });

  group('头像：展示层 sanitize + 非法时阻止保存', () {
    testWidgets('非法地址给出提示，且保存按钮禁用', (tester) async {
      // 服务端不做 URL 校验（见 Go user_preferences.go 的 AvatarURL 注释），
      // 校验必须在展示层；否则用户会看到「保存成功但值不见了」。
      await pumpCard(tester, loaded: prefs(displayName: '张三'));

      // 同时改昵称：否则「非法地址不提交」意味着根本没有改动，保存行不会渲染。
      // 本用例要验证的是「有其它改动时，非法地址仍能拦住整次保存」。
      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '李四',
      );
      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-avatar-url')),
        'javascript:alert(1)',
      );
      await tester.pumpAndSettle();

      expect(find.text('已忽略非法地址：只接受 http/https 链接'), findsOneWidget);

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('settings-prefs-save')),
      );
      expect(button.onPressed, isNull, reason: '静默丢弃非法地址会让用户反复重试而不知原因');
      expect(saveCalls, 0);
    });

    testWidgets('只有非法地址时保存行不渲染（无任何可提交改动）', (tester) async {
      await pumpCard(tester, loaded: prefs(displayName: '张三'));

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-avatar-url')),
        'javascript:alert(1)',
      );
      await tester.pumpAndSettle();

      expect(find.text('已忽略非法地址：只接受 http/https 链接'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-prefs-save')),
        findsNothing,
        reason: '非法值不被提交，故不构成改动',
      );
    });

    testWidgets('非法地址不被提交（即使其它字段有改动）', (tester) async {
      await pumpCard(tester, loaded: prefs(displayName: '张三'));

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '李四',
      );
      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-avatar-url')),
        'data:image/png;base64,AAAA',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(saveCalls, 0, reason: '有非法字段时整次保存都不该发出');
    });

    testWidgets('合法 http/https 地址可保存', (tester) async {
      await pumpCard(tester, loaded: prefs(displayName: '张三'));

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-avatar-url')),
        'https://cdn.example.com/a.png',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.avatarUrl, 'https://cdn.example.com/a.png');
      expect(saveCalls, 1);
    });

    testWidgets('清空头像提交空串（清除自设头像）', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(avatarUrl: 'https://cdn.example.com/a.png'),
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-avatar-url')),
        '',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.avatarUrl, '');
    });

    testWidgets('昵称输入框的占位显示回落值', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(displayName: ''),
        fallbackDisplayName: 'u1@example.com',
      );

      expect(
        find.text('u1@example.com'),
        findsOneWidget,
        reason: '用户应一眼看到「不填的话会显示成什么」',
      );
    });
  });

  group('加载与保存失败', () {
    testWidgets('加载失败时整块退化为错误 + 重试（不渲染空表单）', (tester) async {
      await pumpCard(
        tester,
        loadError: const HttpError(500, 'HTTP 500', body: '{error: boom}'),
      );

      expect(
        find.byKey(const ValueKey('settings-prefs-load-error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        findsNothing,
        reason: '空表单看起来像「你的偏好是空的」，用户可能就此覆盖掉真实值',
      );
    });

    testWidgets('保存失败展示服务端文案（不是 "HTTP 400"）', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(displayName: '张三'),
        // 用一个**不带** reply_language 的 400：带它会被翻译成专门的中文文案
        // （见下一个用例），本用例要验证的是通用路径下服务端原文被透出。
        saveError: const HttpError(
          400,
          'HTTP 400',
          body: '{error: invalid avatar_url, supported: [http, https]}',
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '李四',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-prefs-error')),
        findsOneWidget,
      );
      // `HttpError.message` 恒为 "HTTP 400"，服务端文案在 body 里；直接显示
      // message 等于什么都没说。
      expect(find.text('HTTP 400'), findsNothing);
      expect(find.textContaining('invalid avatar_url'), findsOneWidget);
    });

    testWidgets('非法语言 400 → 给出带改法的中文文案', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(displayName: '张三'),
        saveError: const HttpError(
          400,
          'HTTP 400',
          body: '{error: unsupported reply_language: fr}',
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '李四',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(find.text('不支持这个回复语言，请从列表里重新选择'), findsOneWidget);
    });

    testWidgets('401 → 提示重新登录', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(displayName: '张三'),
        saveError: const HttpError(401, 'HTTP 401'),
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '李四',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(find.text('登录已过期，请重新登录'), findsOneWidget);
    });

    testWidgets('网络错误 → 提示检查网络', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(displayName: '张三'),
        saveError: const NetworkError('timeout'),
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-prefs-display-name')),
        '李四',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
    });
  });

  group('sanitizeAvatarUrl（展示层白名单）', () {
    test('放行 http / https', () {
      expect(
        sanitizeAvatarUrl('https://cdn.example.com/a.png'),
        'https://cdn.example.com/a.png',
      );
      expect(
        sanitizeAvatarUrl('http://example.com/a.png'),
        'http://example.com/a.png',
      );
    });

    test('去掉首尾空白', () {
      expect(
        sanitizeAvatarUrl('  https://example.com/a.png  '),
        'https://example.com/a.png',
      );
    });

    test('拒绝 javascript: / data: / file:（防本地读取与脚本执行）', () {
      expect(sanitizeAvatarUrl('javascript:alert(1)'), isNull);
      expect(sanitizeAvatarUrl('data:image/png;base64,AAAA'), isNull);
      expect(sanitizeAvatarUrl('file:///etc/passwd'), isNull);
    });

    test('拒绝无 scheme 的串与相对路径', () {
      expect(sanitizeAvatarUrl('example.com/a.png'), isNull);
      expect(sanitizeAvatarUrl('/a.png'), isNull);
    });

    test('拒绝有 scheme 但无 host 的串（加载不出来）', () {
      expect(sanitizeAvatarUrl('https://'), isNull);
      expect(sanitizeAvatarUrl('http://'), isNull);
    });

    test('空串返回 null（空 = 未设置，由调用方先判空）', () {
      expect(sanitizeAvatarUrl(''), isNull);
      expect(sanitizeAvatarUrl('   '), isNull);
    });
  });

  group('新建对话默认开关（两个 bool 各自只提交自己的键）', () {
    testWidgets('初值来自权威值', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(followUpSuggest: true, habitSuggest: false),
      );

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('pref-follow-up-suggest')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('pref-habit-suggest')),
            )
            .value,
        isFalse,
      );
    });

    testWidgets('只动 follow-up 时 body 只含 follow_up_suggest', (tester) async {
      await pumpCard(tester, loaded: prefs());

      await tester.tap(find.byKey(const ValueKey('pref-follow-up-suggest')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.followUpSuggest, isTrue);
      expect(lastSave!.habitSuggest, isNull, reason: '没碰的字段必须为 null');
      expect(lastSave!.displayName, isNull);
      expect(lastSave!.replyLanguage, isNull);
      expect(lastSave!.habitNotifyChannels, isNull);
    });

    testWidgets('只动 habit 时 body 只含 habit_suggest', (tester) async {
      await pumpCard(tester, loaded: prefs());

      await tester.tap(find.byKey(const ValueKey('pref-habit-suggest')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.habitSuggest, isTrue);
      expect(lastSave!.followUpSuggest, isNull, reason: '没碰的字段必须为 null');
      expect(lastSave!.displayName, isNull);
      expect(lastSave!.habitNotifyChannels, isNull);
    });

    testWidgets('关掉已开的开关会提交 false（不是 null）', (tester) async {
      // 写成 `if (x == true)` 就永远关不掉。
      await pumpCard(tester, loaded: prefs(habitSuggest: true));

      await tester.tap(find.byKey(const ValueKey('pref-habit-suggest')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.habitSuggest, isFalse);
    });

    testWidgets('未改动时不显示保存按钮（两个开关也不误报改动）', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(followUpSuggest: true, habitSuggest: true),
      );

      expect(find.byKey(const ValueKey('settings-prefs-save')), findsNothing);
      expect(saveCalls, 0);
    });
  });

  group('习惯推送渠道（单个逗号分隔串，不是数组）', () {
    testWidgets('选项来自服务端 available_channels（不自算中文名）', (tester) async {
      await pumpCard(tester, loaded: prefs());

      expect(find.text('微信'), findsOneWidget);
      expect(find.text('钉钉'), findsOneWidget);
    });

    testWidgets('只勾选渠道 A → body 只含 habit_notify_channels，值为该渠道串', (
      tester,
    ) async {
      await pumpCard(tester, loaded: prefs());

      await tester.tap(
        find.byKey(const ValueKey('pref-habit-channel-dingtalk')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.habitNotifyChannels, 'dingtalk');
      // 其它字段一个都不能被带上（部分更新语义）。
      expect(lastSave!.displayName, isNull);
      expect(lastSave!.avatarUrl, isNull);
      expect(lastSave!.replyLanguage, isNull);
      expect(lastSave!.defaultAgentId, isNull);
      expect(lastSave!.followUpSuggest, isNull);
      expect(lastSave!.habitSuggest, isNull);
    });

    testWidgets('多选编成逗号串且排序稳定（勾选顺序不产生「未保存」）', (tester) async {
      await pumpCard(tester, loaded: prefs());

      // 反序勾选（先钉钉后微信）仍应得到排序后的串。
      await tester.tap(
        find.byKey(const ValueKey('pref-habit-channel-dingtalk')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('pref-habit-channel-wechat_ilink')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.habitNotifyChannels, 'dingtalk,wechat_ilink');
    });

    testWidgets('已保存的渠道回填为勾选态', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(
          habitNotifyChannels: 'wechat_ilink',
          habitNotifyChannelsSet: true,
        ),
      );

      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('pref-habit-channel-wechat_ilink')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('pref-habit-channel-dingtalk')),
            )
            .value,
        isFalse,
      );
    });

    testWidgets('未设置 → 徒标「自动」，不是「已关闭」', (tester) async {
      await pumpCard(tester, loaded: prefs());

      expect(find.text('自动'), findsOneWidget);
      expect(find.text('已关闭'), findsNothing);
    });

    testWidgets('显式关闭（off）→ 徒标「已关闭」且按钮为「恢复自动」', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(
          habitNotifyChannels: kHabitNotifyOff,
          habitNotifyChannelsSet: true,
        ),
      );

      expect(find.text('已关闭'), findsOneWidget);
      expect(find.text('恢复自动'), findsOneWidget);
    });

    testWidgets('点「关闭推送」提交 off 哨兵（不是空串）', (tester) async {
      // 空串 = 删记录 = 回退「最近入站渠道」→ 推送反而重新打开。
      // 两者语义相反，必须区分。
      await pumpCard(
        tester,
        loaded: prefs(
          habitNotifyChannels: 'dingtalk',
          habitNotifyChannelsSet: true,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('pref-habit-notify-toggle-off')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.habitNotifyChannels, kHabitNotifyOff);
    });

    testWidgets('点「恢复自动」提交空串（删记录）', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(
          habitNotifyChannels: kHabitNotifyOff,
          habitNotifyChannelsSet: true,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('pref-habit-notify-toggle-off')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prefs-save')));
      await tester.pumpAndSettle();

      expect(lastSave!.habitNotifyChannels, '');
    });

    testWidgets('已配置但渠道已失效时给出提示', (tester) async {
      await pumpCard(
        tester,
        loaded: prefs(
          // set=true 但 available_channels 里已无该渠道（用户解绑了）。
          habitNotifyChannels: 'feishu',
          habitNotifyChannelsSet: true,
        ),
      );

      expect(
        find.byKey(const ValueKey('pref-habit-notify-stale')),
        findsOneWidget,
      );
    });

    testWidgets('无可用渠道且未关闭时给出说明且不渲染勾选项', (tester) async {
      await pumpCard(tester, loaded: prefs(availableChannels: const []));

      expect(find.text('你还没有绑定任何可推送的渠道，无法选择'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pref-habit-channel-wechat_ilink')),
        findsNothing,
      );
    });

    testWidgets('脏存量值（多余空白）不误判为「有改动」', (tester) async {
      // 服务端把该串当不透明串存取，历史值可能带空白。若两侧不过同一个
      // 编码函数，这里会平白亮起保存按钮。
      await pumpCard(
        tester,
        loaded: prefs(
          habitNotifyChannels: ' wechat_ilink , dingtalk ',
          habitNotifyChannelsSet: true,
        ),
      );

      expect(find.byKey(const ValueKey('settings-prefs-save')), findsNothing);
      expect(saveCalls, 0);
    });
  });
}

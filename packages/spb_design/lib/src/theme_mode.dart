import 'package:flutter/material.dart';

/// 主题模式偏好的持久化编码。
///
/// ## 为什么编码器放在 `spb_design` 而不是各 app 里
///
/// 偏好键与字符串编码是**跨端契约**：桌面端写 `"dark"`、移动端若读成
/// `"Dark"`，失败方式是**静默**的——`ThemeMode.system` 会成为兜底，用户看到
/// 的只是「我设的深色怎么没了」，没有任何报错。两端各抄一份解析函数正是这种
/// 漂移的温床。
///
/// 放在这里而不是 `spb_data`：本类**不碰存储**，只做 `ThemeMode` ↔ 字符串的
/// 纯映射，而「本应用有哪几种主题模式」属于设计层。`spb_data` 里放它会让
/// 一个纯映射函数依赖 drift。
class SpbThemeMode {
  const SpbThemeMode._();

  /// 偏好键。沿用既有的 `sync.*` 点分风格，`ui.` 前缀表示界面外观。
  static const String prefKey = 'ui.theme_mode';

  /// 全部模式，顺序即 UI 展示顺序。
  static const List<ThemeMode> all = <ThemeMode>[
    ThemeMode.system,
    ThemeMode.light,
    ThemeMode.dark,
  ];

  /// 编码成存储字符串。
  ///
  /// 用 Dart 枚举名的小写形式（`system` / `light` / `dark`）——与
  /// `ThemeMode.name` 一致，且是人可读的，便于排查时直接看库里的值。
  static String encode(ThemeMode mode) => mode.name;

  /// 解析存储字符串。
  ///
  /// 认不出（`null` / 空串 / 拼错 / 旧版本写的别的东西）时返回
  /// [ThemeMode.system] 并**不抛**：偏好是配置而非数据，一个坏值不该让应用
  /// 起不来。与 `PreferencesStore.getBool` 的取舍一致（解析失败返回默认值）。
  static ThemeMode decode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
    }
    return ThemeMode.system;
  }

  /// UI 展示名。
  static String label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };
}

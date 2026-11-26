import 'package:flutter/material.dart';

/// 把 [query] 在 [text] 中的**全部**出现处高亮。
///
/// ## 为什么大小写不敏感
///
/// 两个消费方都是搜索场景：服务端的 `SearchChatTurnsByText` 用 SQLite 的
/// LIKE，而 SQLite 的 LIKE 对 ASCII **默认大小写不敏感**（`search_page.dart`）；
/// 对话内搜索（`spb_domain` 的 `conversation_search.dart`）同样是大小写不敏感匹配。
/// 若高亮用大小写敏感的方式，会出现「搜 `Todo` 命中了 `todo`，但界面上没有
/// 任何高亮」的困惑——用户会以为搜错了。
///
/// ## 为什么不用正则
///
/// 查询词是**用户输入**，含 `.` `*` `(` `[` 等字符时会被当成元字符，既可能抛
/// 异常（`(` 单独出现）也可能匹配到意料之外的位置。字面量子串扫描更可预测，
/// 且 `indexOf` 的循环足够简单、不会因为回溯而变慢。
///
/// ## 空白查询
///
/// [query] 为空时退化为普通 [Text]（不高亮）。调用方不必自己判空——把「无
/// 查询」这个状态在这里吸收掉，避免每个调用点各写一遍分支。
class HighlightedText extends StatelessWidget {
  const HighlightedText({
    super.key,
    required this.text,
    required this.query,
    this.style,
    this.highlightStyle,
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
  });

  /// 原文。
  final String text;

  /// 要高亮的查询词（**字面量**，非正则）。空串时不做任何高亮。
  final String query;

  /// 普通文本样式。
  final TextStyle? style;

  /// 命中处的样式。为 null 时退化为 [style]（此时「高亮」不可见，但文本仍
  /// 正确渲染——调用方应当传入一个有视觉差异的样式）。
  final TextStyle? highlightStyle;

  /// 最大行数。null 表示不限。
  final int? maxLines;

  /// 超出 [maxLines] 时的截断方式。
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    // 空查询 / 空文本：走普通 Text。用 `Text.rich` 渲染无 span 的文本也能工作，
    // 但会多一层 `RichText`，且语义树上多一个节点。
    if (query.isEmpty || text.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    // 下方直接按 `query.length` 从**原文**取片段（保留原文大小写）。这依赖一个
    // 前提：Dart 的 `toLowerCase` 用**简单大小写映射**（每个码点独立、长度不变，
    // 不展开成多码点），故「小写串的下标」恒等于「原文的下标」。
    //
    // 该前提有测试钉住（`spb_ui_test.dart` 的「toLowerCase 长度不变」）。若将来
    // 语言运行时改成完整映射（如土耳其语 `İ` → `i̇`），那条测试会失败，指向这里。
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;

    // 循环而非 `split`：需要保留**原文**的大小写（`split` 会丢掉分隔符原文，
    // 只能拿到小写化的匹配片段）。
    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index < 0) {
        // 尾部剩余（可能为空串——空 span 无害且省一个分支）。
        spans.add(TextSpan(text: text.substring(start), style: style));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index), style: style));
      }
      // 上方的「长度不变」前提保证了「小写串下标 == 原文下标」，故可直接按
      // `query.length` 取原文片段（保留原文大小写）。
      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: highlightStyle ?? style,
        ),
      );
      start = index + query.length;
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// spec JSON（JsonUiSchema）渲染卡：消费 [SpecUiDocument]，按元素 type 分派。
///
/// ## 范围界定（这是受限渲染器，不是 webapp 的通用 renderer）
///
/// 服务端三类 spec 生产者只产出白名单 type（card/progress/metric/text/heading/
/// button/list/listitem/separator/badge/alert/code）与两类动作
/// （copy_text / send_next_input）——全部由**确定性 Go 代码**编译，非 LLM 生成
/// UI。webapp 的 JsonUiSchemaRenderer 有 40+ type 分支，是为「将来可能有人用」
/// 服务的；Flutter 只需要覆盖**实际产出**，未知 type 降级为不崩占位
/// （服务端新增 type 时老客户端的其他部分照常渲染）。
///
/// ## 动作经 [onAction] 上抛，页面不直接产生副作用
///
/// 渲染层不知道「回填输入框」和「发送消息」怎么实现（那是 app 层装配），故只
/// 上抛动作对象。copy_text 的语义按既有定案降级：**优先回填
/// 输入框**（对齐 webapp onAppend 行为），剪贴板写入由调用方按平台能力决定。
class SpecUiCard extends StatelessWidget {
  const SpecUiCard({super.key, required this.doc, this.onAction});

  /// 解析后的 spec 文档。null 时整体不渲染（调用方可直接跳过）。
  final SpecUiDocument? doc;

  /// 用户点按钮时上抛的动作。null 时按钮禁用（只读展示）。
  final void Function(SpecUiAction action)? onAction;

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final root = d?.root;
    if (d == null || root == null) return const SizedBox.shrink();

    return _SpecElementView(
      element: root,
      doc: d,
      isRoot: true,
      onAction: onAction,
    );
  }
}

/// 单个 spec 元素的渲染（递归下钻 children）。
class _SpecElementView extends StatelessWidget {
  const _SpecElementView({
    required this.element,
    required this.doc,
    required this.isRoot,
    required this.onAction,
  });

  final SpecUiElement element;
  final SpecUiDocument doc;

  /// 根元素包 Card 容器；子元素不再包（避免层层嵌套卡片）。
  final bool isRoot;

  final void Function(SpecUiAction action)? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final children = doc.childrenOf(element);

    switch (element.type) {
      case SpecUiType.card:
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (element.prop('title').isNotEmpty) ...[
              Text(
                element.prop('title'),
                style: textTheme.labelLarge?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: SpbSpacing.sm),
            ],
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
                child: _SpecElementView(
                  element: child,
                  doc: doc,
                  isRoot: false,
                  onAction: onAction,
                ),
              ),
          ],
        );
        if (!isRoot) return body;
        return Card(
          color: scheme.secondaryContainer,
          child: Padding(padding: SpbSpacing.cardPadding, child: body),
        );

      case SpecUiType.text:
        final content = element.prop('content');
        final text = content.isNotEmpty ? content : element.prop('text');
        if (text.isEmpty) return const SizedBox.shrink();
        return Text(
          text,
          style: textTheme.bodyMedium?.copyWith(
            color: scheme.onSecondaryContainer,
          ),
        );

      case SpecUiType.heading:
        final content = element.prop('content');
        final text = content.isNotEmpty ? content : element.prop('text');
        if (text.isEmpty) return const SizedBox.shrink();
        return Text(
          text,
          style: textTheme.titleMedium?.copyWith(
            color: scheme.onSecondaryContainer,
          ),
        );

      case SpecUiType.progress:
        // 0–100 夹紧：webapp renderProgress 同语义；坏值（NaN/超界）不崩。
        final raw = element.propNum('value') ?? 0;
        final value = raw.isNaN ? 0.0 : raw.clamp(0, 100).toDouble();
        final label = element.prop('label');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label.isNotEmpty) Text(label, style: textTheme.bodySmall),
            const SizedBox(height: SpbSpacing.xs),
            LinearProgressIndicator(
              key: const ValueKey('spec-progress-bar'),
              value: value / 100,
            ),
          ],
        );

      case SpecUiType.metric:
        // 字段对齐 webapp renderMetric：label ?? title、value ?? content、
        // hint ?? description。
        final label = element.prop('label').isNotEmpty
            ? element.prop('label')
            : element.prop('title');
        final value = element.prop('value').isNotEmpty
            ? element.prop('value')
            : element.prop('content');
        final hint = element.prop('hint').isNotEmpty
            ? element.prop('hint')
            : element.prop('description');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label.isNotEmpty) Text(label, style: textTheme.bodySmall),
            if (value.isNotEmpty)
              Text(
                value,
                key: const ValueKey('spec-metric-value'),
                style: textTheme.titleMedium?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            if (hint.isNotEmpty)
              Text(
                hint,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        );

      case SpecUiType.button:
        final label = element.prop('label');
        final action = element.actions.isEmpty ? null : element.actions.first;
        return FilledButton.tonal(
          key: ValueKey('spec-button-$label'),
          onPressed:
              (onAction != null &&
                  action != null &&
                  action.type != SpecUiActionType.unknown)
              ? () => onAction!(action)
              : null,
          child: Text(label),
        );

      case SpecUiType.list:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(bottom: SpbSpacing.xs),
                child: _SpecElementView(
                  element: child,
                  doc: doc,
                  isRoot: false,
                  onAction: onAction,
                ),
              ),
          ],
        );

      case SpecUiType.listItem:
        final text =
            element.prop('content') +
            (children.isNotEmpty
                ? children.map((c) => c.prop('content')).join()
                : '');
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• ', style: textTheme.bodyMedium),
            Expanded(child: Text(text, style: textTheme.bodyMedium)),
          ],
        );

      case SpecUiType.separator:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: SpbSpacing.xs),
          child: Divider(height: 1),
        );

      case SpecUiType.badge:
        final label = element.prop('label').isNotEmpty
            ? element.prop('label')
            : element.prop('text');
        if (label.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SpbSpacing.sm,
            vertical: SpbSpacing.xs / 2,
          ),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(SpbRadius.sm),
          ),
          child: Text(label, style: textTheme.labelSmall),
        );

      case SpecUiType.alert:
        final content = element.prop('content');
        final text = content.isNotEmpty ? content : element.prop('text');
        return Text(
          text,
          style: textTheme.bodyMedium?.copyWith(color: scheme.error),
        );

      case SpecUiType.code:
        final content =
            element.prop('content') +
            element.prop('code') +
            element.prop('text');
        if (content.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(SpbSpacing.sm),
          color: scheme.surfaceContainerHighest,
          child: Text(content, style: textTheme.bodySmall),
        );

      case SpecUiType.unknown:
        // 白名单之外：不崩、不渲染语义内容，留一个占位标记（诊断可辨）。
        return Text(
          '（不支持的组件类型：${element.type.name}）',
          key: const ValueKey('spec-unknown-placeholder'),
          style: textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        );
    }
  }
}

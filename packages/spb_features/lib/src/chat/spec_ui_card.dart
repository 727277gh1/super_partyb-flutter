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
/// ## 未知类型必须**照常下钻**（issue #27）
///
/// 真实生产看板（`dashboard.spec.json`）的容器是 `Stack` / `Grid`、叶子是
/// `Chart` / `Table`——**都不在白名单里**。若未知类型直接截断，从 root 起第一跳
/// 就把整棵子树吞掉，连白名单内的 `Metric`（「上证指数 3864.37」）也一起没了，
/// 比「退回 JSON 原文」更差。故未知类型一律：
///
/// - **有子元素** → 递归渲染子元素（对齐 webapp `renderFallback`）；
/// - **无子元素**（叶子） → 渲染占位标记，且打印**原始 type 字符串**。
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
      // 渲染路径的环检测：**必须**传下来，否则 A→B→A 这种互相引用会无限递归。
      // 解析层的 `visited` 只保护 `childrenOf`，保护不到渲染层的递归。
      visited: <String>{root.id},
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
    required this.visited,
  });

  final SpecUiElement element;
  final SpecUiDocument doc;

  /// 根元素包 Card 容器；子元素不再包（避免层层嵌套卡片）。
  final bool isRoot;

  final void Function(SpecUiAction action)? onAction;

  /// **祖先**元素 id 集合（不含 [element] 自身）。渲染前先查这里——已在集合中
  /// 说明成环，直接停。
  final Set<String> visited;

  /// 递归渲染直接子元素（携带环检测集合）。
  ///
  /// 用 [SpecUiDocument.directChildrenOf] 而**不是** `childrenOf`：后者返回整棵
  /// 子树的扁平列表，再对每一项递归会让深层元素渲染多次（实测 3 层树的叶子出现
  /// 2 次）。
  Widget _childrenColumn(
    List<SpecUiElement> children, {
    double spacing = SpbSpacing.sm,
  }) {
    final next = {...visited, element.id};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final child in children)
          Padding(
            padding: EdgeInsets.only(bottom: spacing),
            child: visited.contains(child.id)
                // 成环：该分支到此为止（与解析层同一判据）。
                ? const SizedBox.shrink()
                : _SpecElementView(
                    element: child,
                    doc: doc,
                    isRoot: false,
                    onAction: onAction,
                    visited: next,
                  ),
          ),
      ],
    );
  }

  /// 叶子未知类型的占位标记。
  ///
  /// 显示 [SpecUiElement.rawType] 而不是 `type.name`——枚举会把 `Stack` /
  /// `Grid` / `Chart` 全部塌缩成 `unknown`，那种占位符没有诊断价值（issue #27）。
  /// `rawType` 为空（服务端没写 `type` 字段）时才退回枚举名。
  Widget _unknownLeaf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final label = element.rawType.isEmpty ? element.type.name : element.rawType;
    return Text(
      '（不支持的组件类型：$label）',
      key: ValueKey('spec-unknown-${element.id}'),
      style: textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final children = doc.directChildrenOf(element);

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
            _childrenColumn(children),
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
            // 进度条对屏幕阅读器是**完全空白**的：它是个自绘的圆角矩形，
            // 没有可读文本。`value` 非空时 Flutter 会把比例当 `value` 念出来
            // （如「已完成 60%」的 60%），但**念不出这是什么的 60%**。
            // 故必须给 `semanticsLabel`。
            //
            // 不传 `semanticsValue`：`value != null` 时 Flutter 已把它算成
            // 百分比并交给屏幕阅读器，手写一份只会多一个需要同步的真源。
            //
            // `label` 为空时**不编一个「进度」**：那种标签对用户零信息（同
            // issue #24 备注里的「不给装饰图标加 label: '图标'」）。此时保留
            // Flutter 默认的百分比读数即可。
            LinearProgressIndicator(
              key: const ValueKey('spec-progress-bar'),
              value: value / 100,
              semanticsLabel: label.isEmpty ? null : label,
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
        // 列表用更紧的行距（保持既有视觉，与 card 的 sm 区分）。
        return _childrenColumn(children, spacing: SpbSpacing.xs);

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
        // 字段对齐 webapp renderAlert：`message ?? description ?? content ??
        // text`。**`message` 必须在前**——上游真实产出（含 `realDashboardDoc`）
        // 用的是 `{title, message}` 形状，漏掉它会让整条告警渲染成空文本
        // （`Text('')` 占位但不显示任何东西，比不渲染更难排查）。
        //
        // `title` 也一并渲染：webapp 的 AlertTitle 是独立元素，丢掉它会让
        // 「关键信号」这类标题消失，用户只看得到正文而不知道那是什么。
        final alertTitle = element.prop('title');
        final content = element.prop('content');
        final message = element.prop('message').isNotEmpty
            ? element.prop('message')
            : content.isNotEmpty
            ? content
            : element.prop('description').isNotEmpty
            ? element.prop('description')
            : element.prop('text');
        if (alertTitle.isEmpty && message.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (alertTitle.isNotEmpty)
              Text(
                alertTitle,
                style: textTheme.labelLarge?.copyWith(color: scheme.error),
              ),
            if (message.isNotEmpty)
              Text(
                message,
                style: textTheme.bodyMedium?.copyWith(color: scheme.error),
              ),
          ],
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
        // 未知**容器**：照常下钻（对齐 webapp renderFallback），不阻断子树。
        // 真实看板的 Stack / Grid 走这条路径——它们的子元素里有白名单类型
        // （Metric / Alert），截断会让这些本来能渲染的内容消失（issue #27）。
        if (children.isNotEmpty) return _childrenColumn(children);
        // 未知**叶子**：没有可渲染的内容，给占位标记（带原始 type 名）。
        return _unknownLeaf(context);
    }
  }
}

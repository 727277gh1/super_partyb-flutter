import 'package:flutter/material.dart';

/// Windows 单列列表的方向键按条目顺序移动焦点。
class SpbVerticalListFocus extends StatelessWidget {
  const SpbVerticalListFocus({super.key, required this.child});

  final Widget child;

  /// 将焦点交给条目的主操作，复用控件的焦点反馈和 Enter 激活行为。
  static Widget item(
    BuildContext context, {
    Key? key,
    required int index,
    required Widget Function(FocusNode? focusNode) builder,
  }) {
    if (FocusTraversalGroup.maybeOf(context) is! _VerticalListPolicy) {
      return builder(null);
    }
    return _VerticalListItem(key: key, index: index, builder: builder);
  }

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.windows) return child;
    return FocusTraversalGroup(policy: _VerticalListPolicy(), child: child);
  }
}

class _VerticalListItem extends StatefulWidget {
  const _VerticalListItem({
    super.key,
    required this.index,
    required this.builder,
  });

  final int index;
  final Widget Function(FocusNode focusNode) builder;

  @override
  State<_VerticalListItem> createState() => _VerticalListItemState();
}

class _VerticalListItemState extends State<_VerticalListItem> {
  late final _ListItemFocusNode _focusNode = _ListItemFocusNode(widget.index);

  @override
  Widget build(BuildContext context) {
    _focusNode.index = widget.index;
    return widget.builder(_focusNode);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }
}

class _ListItemFocusNode extends FocusNode {
  _ListItemFocusNode(this.index);

  int index;
}

class _VerticalListPolicy extends ReadingOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final step = switch (direction) {
      TraversalDirection.up => -1,
      TraversalDirection.down => 1,
      _ => 0,
    };
    if (currentNode is! _ListItemFocusNode || step == 0) {
      return super.inDirection(currentNode, direction);
    }

    // 只在同一列表的主操作间移动，行内菜单和其他控件仍可用 Tab 聚焦。
    _ListItemFocusNode? target;
    var nearest = double.infinity;
    for (final node in currentNode.nearestScope!.traversalDescendants) {
      if (node is! _ListItemFocusNode ||
          FocusTraversalGroup.maybeOfNode(node) != this) {
        continue;
      }
      final distance = (node.index - currentNode.index) * step;
      if (distance > 0 && distance < nearest) {
        target = node;
        nearest = distance.toDouble();
      }
    }
    if (target == null) return false;
    requestFocusCallback(
      target,
      alignmentPolicy: step > 0
          ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
          : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
    return true;
  }
}

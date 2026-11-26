import 'dart:async';

import 'package:flutter/material.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// 前台用应用内提示，后台交给系统通知；两端共享同一个组件。
class NoticeBanner extends StatefulWidget {
  const NoticeBanner({
    super.key,
    required this.center,
    required this.focused,
    required this.onOpen,
    required this.child,
  });
  final NoticeCenter? center;
  final bool focused;
  final void Function(String route) onOpen;
  final Widget child;

  @override
  State<NoticeBanner> createState() => _NoticeBannerState();
}

class _NoticeBannerState extends State<NoticeBanner> {
  StreamSubscription<NoticeSnapshot>? _subscription;
  final _seen = <String, String>{};
  Notice? _notice;
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(NoticeBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.center != widget.center) {
      _subscription?.cancel();
      _expiry?.cancel();
      _seen.clear();
      _notice = null;
      _attach();
    }
  }

  void _attach() {
    _subscription = widget.center?.changes.listen(_receive);
  }

  void _receive(NoticeSnapshot snapshot) {
    if (!mounted) return;
    Notice? next;
    for (final notice in snapshot.notices) {
      if (notice.isRead && _notice?.id == notice.id) _notice = null;
      if (!notice.isRead && _seen[notice.id] != notice.revision) {
        next ??= notice;
      }
      _seen[notice.id] = notice.revision;
    }
    while (_seen.length > 4096) {
      _seen.remove(_seen.keys.first);
    }
    if (widget.focused && next != null) {
      _notice = next;
      _expiry?.cancel();
      _expiry = Timer(const Duration(seconds: 15), () {
        if (mounted) setState(() => _notice = null);
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (widget.focused && _notice != null)
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: Text(
                    _notice!.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _notice!.displayBody(DateTime.now()),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    final route = _notice!.route;
                    setState(() => _notice = null);
                    widget.onOpen(route);
                  },
                  trailing: IconButton(
                    // 图标按钮没有可读文本：没有语义名称时读屏只能念「按钮」（#129）。
                    //
                    // ⚠️ 用 `Icon.semanticLabel` 而**不是** `IconButton.tooltip`：
                    // 本组件挂在 `MaterialApp.builder` 上，位于 **Navigator 之上**
                    // （两端 `app.dart` 都是这么接的），那儿没有 `Overlay`——
                    // `Tooltip` 会断言 `debugCheckHasOverlay` 直接抛异常。
                    // 测试里把 banner 放进 `MaterialApp(home:)` 才「看起来正常」，
                    // 这类假绿由 `notice_banner_test.dart` 的「无 Overlay 祖先」用例守。
                    //
                    // 不再自带 padding：M3 的 IconButton 已保证 48dp 命中区，
                    // 默认内边距就是 8dp，显式再写一遍只会造成
                    // 「以为这里是尺寸来源」的错觉。
                    onPressed: () => setState(() => _notice = null),
                    icon: const Icon(Icons.close, semanticLabel: '关闭通知'),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

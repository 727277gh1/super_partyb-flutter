import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 两端共用站内通知中心；显示通知不会自动把别端的未读状态清掉。
class NoticeCenterCard extends StatefulWidget {
  const NoticeCenterCard({super.key, required this.center, this.onOpen});

  final NoticeCenter center;
  final void Function(String route)? onOpen;

  @override
  State<NoticeCenterCard> createState() => _NoticeCenterCardState();
}

class _NoticeCenterCardState extends State<NoticeCenterCard> {
  bool _busy = false;
  String? _error;

  Future<void> _markRead({String? id}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.center.markRead(
        ids: id == null ? const [] : [id],
        all: id == null,
      );
    } catch (_) {
      // 错误在通知中心内保留，用户可重试；不能先乐观清掉服务端未读状态。
      if (mounted) setState(() => _error = '标记已读失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<NoticeSnapshot>(
    stream: widget.center.changes,
    initialData: widget.center.snapshot,
    builder: (context, snapshot) {
      final state = snapshot.data ?? widget.center.snapshot;
      final error = _error ?? state.error;
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(SpbSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.notifications_outlined),
                  const SizedBox(width: SpbSpacing.sm),
                  Expanded(
                    child: Text(
                      '通知中心${state.unread > 0 ? ' · ${state.unread} 条未读' : ''}',
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新通知',
                    onPressed: () => widget.center.refresh(),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const Text('通知在各客户端共享；点击“标记已读”后同步已读状态。'),
              if (error != null)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (state.unread > 0)
                TextButton(
                  onPressed: _busy ? null : () => _markRead(),
                  child: const Text('全部标记已读'),
                ),
              if (state.notices.isEmpty && error == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: SpbSpacing.md),
                  child: Text('暂无通知'),
                ),
              if (state.notices.isNotEmpty)
                SizedBox(
                  height: 360,
                  child: ListView.separated(
                    itemCount: state.notices.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final notice = state.notices[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          notice.severity == 'info'
                              ? Icons.notifications_outlined
                              : Icons.warning_amber_outlined,
                          color: notice.isRead
                              ? null
                              : Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(
                          '${notice.isRead ? '' : '● '}${notice.title}',
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(notice.displayBody(DateTime.now())),
                            Text(
                              (notice.updatedAt ?? notice.createdAt)
                                  .toLocal()
                                  .toString()
                                  .split('.')
                                  .first,
                            ),
                            Wrap(
                              children: [
                                if (notice.deepLinkGroupId != null &&
                                    widget.onOpen != null)
                                  TextButton(
                                    onPressed: () =>
                                        widget.onOpen!(notice.route),
                                    child: const Text('查看对话'),
                                  ),
                                if (!notice.isRead)
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _markRead(id: notice.id),
                                    child: const Text('标记已读'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

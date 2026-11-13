import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

/// 水位只在整页保存成功后推进，与 SSE 游标及普通消息缓冲完全独立。
class VisualizationRecovery {
  VisualizationRecovery({
    required this.groupId,
    required this.fetch,
    required this.save,
    this.clear,
  });

  final String groupId;
  final void Function()? clear;
  final Future<VisualizationRecoveryPage> Function(int after, int? through)
  fetch;
  final void Function(List<ChatEvent>) save;
  int _after = 0;
  int? _through;
  bool _stopped = false;
  Future<void>? _running;

  void stop() => _stopped = true;

  Future<void> refresh() {
    if (_stopped) return Future.value();
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    var reset = false;
    do {
      VisualizationRecoveryPage page;
      try {
        page = await fetch(_after, _through);
      } on HttpError catch (e) {
        if (!reset &&
            e.statusCode == 409 &&
            e.errorCode == 'cursor_reset_required') {
          if (_stopped) return;
          clear?.call();
          _after = 0;
          _through = null;
          reset = true;
          continue;
        }
        rethrow;
      }
      if (_stopped) return;
      final high = page.throughGlobalSeq;
      final next = page.nextAfterGlobalSeq;
      if (high < _after ||
          next < _after ||
          next > high ||
          (_through != null && high != _through) ||
          (page.hasMore ? next <= _after || next >= high : next != high)) {
        throw const FormatException('可视化恢复游标无效');
      }
      var previous = _after;
      for (final event in page.items) {
        final seq = event.globalSeq;
        if (event.eventId.isEmpty ||
            event.turnId.isEmpty ||
            event.groupId != groupId ||
            event.eventType != EventTypes.visualizationPublished ||
            seq == null ||
            seq <= previous ||
            seq > next) {
          throw const FormatException('可视化恢复事件无效');
        }
        previous = seq;
      }
      if (page.hasMore && previous != next) {
        throw const FormatException('可视化恢复页不完整');
      }
      _through = high;
      save(page.items);
      _after = next;
      if (!page.hasMore) {
        _through = null;
        return;
      }
    } while (!_stopped);
  }
}

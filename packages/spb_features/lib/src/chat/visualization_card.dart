import 'package:flutter/material.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'spec_ui_card.dart';

typedef LoadVisualization = Future<VisualizationRevision> Function(
  String groupId,
  String artifactId,
  int revision,
);

class VisualizationCard extends StatefulWidget {
  const VisualizationCard({super.key, required this.item, this.load});
  final VisualizationItem item;
  final LoadVisualization? load;
  @override
  State<VisualizationCard> createState() => _VisualizationCardState();
}

class _VisualizationCardState extends State<VisualizationCard> {
  bool _opened = false;
  bool _loading = false;
  bool _failed = false;
  SpecUiDocument? _doc;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant VisualizationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.groupId != widget.item.groupId) {
      _generation++;
      _opened = false;
      _loading = false;
      _failed = false;
      _doc = null;
    }
  }

  Future<void> _load() async {
    final load = widget.load;
    if (load == null) return;
    final generation = ++_generation;
    final item = widget.item;
    final ref = item.reference;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final value = await load(item.groupId, ref.artifactId, ref.revision);
      if (value.groupId != item.groupId ||
          value.artifactId != ref.artifactId ||
          value.revision != ref.revision ||
          value.profile != ref.profile ||
          value.schemaVersion != ref.schemaVersion ||
          value.status != 'published') {
        throw const FormatException('可视化版本响应不匹配');
      }
      final doc = parseSpecUi(value.spec);
      if (doc == null) throw const FormatException('报告内容无效');
      if (mounted && generation == _generation) {
        setState(() {
          _doc = doc;
          _loading = false;
        });
      }
    } catch (_) {
      // 卡片展示失败提示并保留摘要，不把接口错误或正文写入诊断日志。
      if (mounted && generation == _generation) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = widget.item.reference;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ref.title.isEmpty ? '可视化报告' : ref.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (ref.summary.isNotEmpty) Text(ref.summary),
            if (!ref.isSupported)
              const Text('当前客户端暂不支持此报告版本。')
            else if (widget.load == null)
              const Text('报告暂时无法加载。')
            else
              TextButton(
                onPressed: () {
                  setState(() => _opened = !_opened);
                  if (_opened && _doc == null && !_loading) _load();
                },
                child: Text(_opened ? '收起报告' : '查看报告'),
              ),
            if (_opened) ...[
              if (_loading) const Text('正在加载报告…'),
              if (_failed)
                Row(
                  children: [
                    const Text('报告加载失败。'),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              if (_doc != null) SpecUiCard(doc: _doc),
            ],
          ],
        ),
      ),
    );
  }
}

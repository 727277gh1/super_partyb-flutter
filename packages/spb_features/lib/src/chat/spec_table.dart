import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 水平滚动保留全部列，分页只限制同时构建的行数，不截断报告内容。
class SpecTable extends StatefulWidget {
  const SpecTable({super.key, required this.element});
  final SpecUiElement element;

  @override
  State<SpecTable> createState() => _SpecTableState();
}

class _SpecTableState extends State<SpecTable> {
  int _page = 0;

  @override
  void didUpdateWidget(SpecTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.element, widget.element)) _page = 0;
  }

  @override
  Widget build(BuildContext context) {
    final element = widget.element;
    final rawColumns = element.props['columns'];
    final rawRows = element.props['rows'];
    final rows = rawRows is List<Object?> ? rawRows : const <Object?>[];
    final columns = <({String key, String label})>[];
    if (rawColumns is List<Object?>) {
      for (final raw in rawColumns) {
        final key = raw is String
            ? raw
            : raw is Map<Object?, Object?>
            ? (raw['key'] ?? raw['id'] ?? raw['field'] ?? '').toString()
            : '';
        if (key.isEmpty) continue;
        final label = raw is Map<Object?, Object?>
            ? (raw['label'] ?? raw['title'] ?? key).toString()
            : key;
        columns.add((key: key, label: label));
      }
    }
    final pageSize = (element.propNum('pageSize') ?? 20).clamp(1, 200).toInt();
    final pages = (rows.length / pageSize).ceil();
    final page = _page.clamp(0, pages > 0 ? pages - 1 : 0);
    final title = element.prop('title');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
            child: Text(
              title,
              style: SpbType.cardTitle(Theme.of(context).textTheme),
            ),
          ),
        if (columns.isEmpty)
          const Text('暂无表格列定义')
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 48,
              dataRowMinHeight: 44,
              dataRowMaxHeight: double.infinity,
              columns: [
                for (final col in columns) DataColumn(label: Text(col.label)),
              ],
              rows: [
                for (final row in rows.skip(page * pageSize).take(pageSize))
                  DataRow(
                    cells: [
                      for (final col in columns)
                        DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: SpbSpacing.sm,
                              ),
                              child: Text(
                                _cellText(
                                  row is Map<Object?, Object?>
                                      ? row[col.key]
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        if (rows.isEmpty && columns.isNotEmpty) const Text('暂无数据'),
        if (pages > 1)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '上一页',
                onPressed: page > 0
                    ? () => setState(() => _page = page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Flexible(child: Text('${page + 1}/$pages 页 · ${rows.length} 行')),
              IconButton(
                tooltip: '下一页',
                onPressed: page + 1 < pages
                    ? () => setState(() => _page = page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
      ],
    );
  }
}

String _cellText(Object? value) {
  if (value == null) return '';
  if (value is Map<Object?, Object?> || value is List<Object?>) {
    return jsonEncode(value);
  }
  return value.toString();
}

/// 对齐 PartyB 的 realDashboardDoc：数据来自 state，图表未显式声明 series。
Map<String, Object?> realDashboardSpec() => {
  'root': 'dashboard',
  'state': {
    'data': {
      'closes': [
        {'date': '7/16', 'sh': 3882.41, 'sz': 14488.65, 'cyb': 3692.46},
        {'date': '7/17', 'sh': 3764.16, 'sz': 13706.88, 'cyb': 3428.63},
        {'date': '7/18', 'sh': 3810.55, 'sz': 13950.12, 'cyb': 3501.28},
        {'date': '7/21', 'sh': 3864.37, 'sz': 14264.29, 'cyb': 3685.97},
      ],
      'rows': [
        {'指数': '上证指数', '7/16': 3882.41, '7/17': 3764.16, '7/21': 3864.37},
        {'指数': '深证成指', '7/16': 14488.65, '7/17': 13706.88, '7/21': 14264.29},
      ],
    },
  },
  'elements': {
    'dashboard': {
      'type': 'Stack',
      'props': {'gap': 'md'},
      'children': ['kpi-row', 'trend-chart', 'alert-box', 'data-table'],
    },
    'kpi-row': {
      'type': 'Grid',
      'props': {'columns': 3, 'gap': 'md'},
      'children': ['kpi-sh', 'kpi-sz', 'kpi-cyb'],
    },
    'kpi-sh': {
      'type': 'Metric',
      'props': {'title': '上证指数', 'value': '3864.37', 'description': '7/21 收盘'},
    },
    'kpi-sz': {
      'type': 'Metric',
      'props': {'title': '深证成指', 'value': '14264.29'},
    },
    'kpi-cyb': {
      'type': 'Metric',
      'props': {'title': '创业板指', 'value': '3685.97'},
    },
    'trend-chart': {
      'type': 'Chart',
      'props': {
        'title': '三大指数近4日收盘走势',
        'chartType': 'line',
        'dataKey': '/data/closes',
        'height': 220,
      },
    },
    'alert-box': {
      'type': 'Alert',
      'props': {'title': '关键信号', 'message': '7/17 单日急跌，随后两日震荡修复。'},
    },
    'data-table': {
      'type': 'Table',
      'props': {
        'title': '收盘明细',
        'columns': [
          {'key': '指数', 'label': '指数'},
          {'key': '7/16', 'label': '7/16'},
          {'key': '7/17', 'label': '7/17'},
          {'key': '7/21', 'label': '7/21'},
        ],
        'rows': {r'$state': '/data/rows'},
        'pageSize': 5,
      },
    },
  },
};

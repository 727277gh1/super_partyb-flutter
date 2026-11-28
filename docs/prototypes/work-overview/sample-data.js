'use strict';

// 示例只使用现有模型可表达的信息，避免原型暗示服务端已提供全局运行状态。
const sampleGroups = [
  {
    id: 'research', title: '行业调研报告', goal: '整理行业变化，形成可复核的调研报告',
    current: '整合结论与引用', completed: 3, localFiles: 2,
    tasks: [
      ['收集资料', '已完成'], ['核对来源', '已完成'], ['整理章节', '已完成'],
      ['整合结论与引用', '进行中'], ['复核报告', '待开始'], ['整理交付物', '待开始'],
    ],
    files: [
      { name: 'reports/调研初稿.md', local: true, text: '# 行业调研初稿\n\n这是交付物预览的示例内容。\n\n## 主要发现\n资料已整理，结论与引用仍待复核。' },
      { name: 'reports/参考资料.md', local: true, text: '# 参考资料\n\n这是用于验证查找路径的示例文件。' },
      { name: 'reports/复核清单.md', local: false, text: '# 复核清单\n\n- 检查引用\n- 核对结论\n- 补充限制条件' },
    ],
  },
  {
    id: 'knowledge', title: '知识库整理', goal: '将零散资料整理为可查找的目录',
    current: '合并重复条目', completed: 1, localFiles: null,
    tasks: [['扫描资料目录', '已完成'], ['合并重复条目', '进行中'], ['生成目录索引', '待开始']],
    files: [{ name: 'notes/资料索引.md', local: false, text: '# 资料索引\n\n这是远端文件的示例，不代表已同步到本地。' }],
  },
  {
    id: 'verification', title: '客户端回归检查', goal: '复核核心页面的交互与布局',
    current: '验证文件预览', completed: 2, localFiles: 1,
    tasks: [['验证登录入口', '已完成'], ['验证列表布局', '已完成'], ['验证文件预览', '失败'], ['整理检查结果', '待开始']],
    files: [{ name: 'reports/检查记录.md', local: true, text: '# 检查记录\n\n文件预览检查未完成，需要查看执行上下文定位问题。' }],
  },
  {
    id: 'archive', title: '历史资料归档', goal: '按主题归档资料并保留来源',
    current: '确认后续整理范围', completed: 1, localFiles: null,
    tasks: [['识别资料主题', '已完成'], ['确认后续整理范围', '阻塞'], ['生成归档索引', '待开始']],
    files: [],
  },
];

const sampleConfirmations = [
  { id: 'confirmation-1', group: 'research', turn: 'round-3', reason: '初稿已整理，是否继续补充来源并复核结论？', expiry: '约 8 分钟后过期' },
  { id: 'confirmation-2', group: 'archive', turn: 'round-2', reason: '已识别现有资料主题，是否继续展开后续整理？', expiry: '未设置过期时间' },
];

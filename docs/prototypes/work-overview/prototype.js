'use strict';

const main = document.querySelector('main');
const dialog = document.querySelector('#dialog');
const scenarioSelect = document.querySelector('#scenario');
const announcement = document.querySelector('#announcement');
let scenario = 'normal';
let activeFilter = 'all';
let lastRoute = '';
let filePreviewCount = 0;
const resolved = new Set();
const scrollPositions = new Map();

const escapeHtml = value => String(value).replace(/[&<>"']/g, character => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[character]);
const groups = () => scenario === 'empty' ? [] : sampleGroups;
const confirmations = () => scenario === 'empty' ? [] : sampleConfirmations.filter(item => !resolved.has(item.id));
const unavailable = () => scenario === 'error' || scenario === 'offline' || scenario === 'loading';
const groupOf = id => groups().find(group => group.id === id);
const pendingOf = group => unavailable() ? null : confirmations().filter(item => item.group === group.id).length;
const problemsOf = group => group.tasks.filter(task => ['失败', '阻塞'].includes(task[1]));
const tag = (label, error = false) => `<span class="tag${error ? ' error' : ''}">${escapeHtml(label)}</span>`;
const routeLink = (path, label, extra = '') => `<a class="button ${extra}" href="#${path}">${escapeHtml(label)}</a>`;
const workLink = (group, tab = 'overview', label = '查看工作') => routeLink(`work/${group.id}/${tab}`, label);
const sourceNote = '<p class="footer-note">目标与任务仅覆盖已加载的工作；文件摘要来自本地同步记录。完整文件清单在打开某个工作的交付物时按需查看。</p>';

function notice() {
  if (scenario === 'error') return '<div class="notice error"><strong>待确认信息暂不可用</strong><p>查询失败不能解释为没有待确认事项；其他工作摘要仍可查看。</p><button data-action="retry">演示重试</button></div>';
  if (scenario === 'offline') return '<div class="notice"><strong>离线缓存 · 示例快照</strong><p>目标、任务与本地文件记录可能已变化。待确认状态无法核实；当前仅可查看缓存上下文。</p></div>';
  if (scenario === 'truncated') return '<div class="notice"><strong>当前结果不完整</strong><p>待确认查询已达上限，数量以“至少”标注；任务异常仅覆盖已加载的 4 个工作，仍有列表页未加载。</p></div>';
  return '';
}

function pageHeading(title, description, action = '') {
  return `<header class="page-heading"><div><h1 tabindex="-1">${escapeHtml(title)}</h1><p class="muted">${escapeHtml(description)}</p></div>${action}</header>`;
}

function pendingLabel() {
  if (unavailable()) return '状态未知';
  return `${scenario === 'truncated' ? '至少 ' : ''}${confirmations().length} 项待确认`;
}

function loadingBody() {
  return '<div class="notice" role="status">正在读取工作与待确认快照…</div><div aria-hidden="true"><div class="placeholder"></div><div class="placeholder"></div><div class="placeholder"></div></div><p class="muted">此状态用于评审加载布局；可在顶部切换回“正常”。</p>';
}

function workCard(group, primaryLink = workLink(group)) {
  const pending = pendingOf(group);
  const issues = problemsOf(group);
  const status = pending > 0 ? '等待确认' : issues.length ? issues[0][1] : '任务进行中';
  return `<article class="card work-card">
    <div class="item-heading"><h3>${escapeHtml(group.title)}</h3>${tag(status, issues.some(task => task[1] === '失败'))}</div>
    <p>${escapeHtml(group.goal)}</p>
    <p class="meta">当前任务：${escapeHtml(group.current)}</p>
    <progress value="${group.completed}" max="${group.tasks.length}" aria-label="${escapeHtml(group.title)}任务进度">${group.completed}/${group.tasks.length}</progress>
    <p class="meta">${group.completed}/${group.tasks.length} 项已完成${pending === null ? ' · 待确认状态未知' : pending > 0 ? ` · ${scenario === 'truncated' ? '至少 ' : ''}${pending} 项待确认` : ''}</p>
    <div class="actions">${primaryLink}${workLink(group, 'tasks', '查看任务')}</div>
  </article>`;
}

function attentionSummary() {
  const problemGroups = groups().filter(group => problemsOf(group).length);
  return `<section id="attention" class="attention-section" aria-labelledby="attention-heading">
    <div class="section-heading"><h2 id="attention-heading" tabindex="-1">需要我处理</h2><span class="meta">确认与任务异常分别展示</span></div>
    <div class="attention-grid">
      <article class="card attention-card"><h3>${pendingLabel()}</h3>
        <p class="muted">${unavailable() ? '尚不能核实是否有工作在等你确认。' : confirmations().length ? escapeHtml(confirmations()[0].reason) : '当前查询内没有待确认事项。'}</p>
        <div class="actions">${routeLink('attention', '查看待确认')}</div>
      </article>
      <article class="card error-card"><h3>任务异常 <span class="meta">· 已加载工作</span></h3>
        ${problemGroups.length ? problemGroups.map(group => `<p>${escapeHtml(group.title)} · ${tag(problemsOf(group)[0][1], problemsOf(group)[0][1] === '失败')}</p>`).join('') : '<p class="muted">已加载工作中未发现失败或阻塞任务。</p>'}
        <div class="actions">${routeLink('issues', '查看异常任务')}</div>
      </article>
    </div>
  </section>`;
}

function filesSummary() {
  return `<section id="deliverables" aria-labelledby="deliverables-heading">
    <div class="section-heading"><h2 id="deliverables-heading" tabindex="-1">交付物</h2><span class="meta">按工作查看</span></div>
    <p class="meta">首页列本地同步记录；无记录不代表远端没有成果。</p>
    ${groups().map(group => `<article class="card"><h3>${escapeHtml(group.title)}</h3><p class="meta">${group.localFiles === null ? '本地暂无同步记录' : `本地记录：已同步 ${group.localFiles} 个文件`}</p><div class="actions">${workLink(group, 'files', '查看交付物')}</div></article>`).join('')}
  </section>`;
}

function overview() {
  const heading = pageHeading('工作概览', '先处理需要你介入的事，再看目标与成果。', '<button class="primary" data-action="capture">快速对话</button>');
  if (scenario === 'loading') return heading + loadingBody();
  if (!groups().length) return heading + '<section class="card empty-state"><h2>还没有工作</h2><p class="muted">从一个需求开始。后续可以在这里查看目标、待确认事项与成果。</p><div class="actions"><button data-action="capture">发起第一次对话</button></div></section>';
  return heading + notice() + `<nav class="jump-links" aria-label="概览分区">
      <a class="button" href="#overview/attention">需要处理<strong>${pendingLabel()}</strong></a>
      <a class="button" href="#overview/current">当前工作<strong>${groups().length} 个已加载</strong></a>
      <a class="button" href="#overview/deliverables">交付物<strong>按工作查看</strong></a>
    </nav><div class="overview-grid">${attentionSummary()}
      <section id="current" aria-labelledby="current-heading"><div class="section-heading"><h2 id="current-heading" tabindex="-1">当前工作</h2><a href="#conversations">查看对话列表</a></div>${groups().map(group => workCard(group)).join('')}</section>
      ${filesSummary()}
    </div>${sourceNote}`;
}

function confirmationRows() {
  if (unavailable()) return '<div class="card"><h2>待确认状态未知</h2><p>恢复查询后才能核实内容；不会展示缓存确认按钮。</p></div>';
  return confirmations().map(item => `<article class="card"><div class="item-heading"><h2>${escapeHtml(groupOf(item.group).title)}</h2>${tag('待确认')}</div><p>${escapeHtml(item.reason)}</p><p class="meta">${escapeHtml(item.expiry)}</p><div class="actions"><button data-action="confirmation" data-id="${item.id}">查看确认</button>${routeLink(`work/${item.group}/chat/${item.turn}`, '查看上下文')}</div></article>`).join('') || '<div class="card empty-state"><h2>当前查询内没有待确认事项</h2><p class="muted">任务失败和阻塞仍可在“查看异常任务”中检查。</p></div>';
}

function attentionPage() {
  return '<a class="back-link" href="#overview">返回工作概览</a>' + pageHeading('待确认事项', pendingLabel()) + notice() + (scenario === 'loading' ? loadingBody() : confirmationRows());
}

function issuesPage() {
  const items = groups().filter(group => problemsOf(group).length);
  return '<a class="back-link" href="#overview">返回工作概览</a>' + pageHeading('异常任务', '仅依据已加载的目标任务快照；阻塞不等于失败。') + notice() + (scenario === 'loading' ? loadingBody() : items.map(group => `<article class="card"><h2>${escapeHtml(group.title)}</h2>${problemsOf(group).map(task => `<p>${tag(task[1], task[1] === '失败')} ${escapeHtml(task[0])}</p>`).join('')}<div class="actions">${workLink(group, 'tasks', '查看任务')}${workLink(group, 'chat', '查看执行上下文')}</div></article>`).join('') || '<div class="card empty-state">已加载工作中未发现失败或阻塞任务。</div>');
}

function conversationsPage() {
  const shown = groups().filter(group => activeFilter === 'all' || (activeFilter === 'confirmation' ? pendingOf(group) > 0 : problemsOf(group).length));
  return pageHeading('对话', '保留按对话查找、继续沟通的入口。', '<button class="primary" data-action="capture">快速对话</button>') + notice() + (scenario === 'loading' ? loadingBody() : `<div class="filter-bar" role="group" aria-label="筛选已加载对话">${[['all', '全部已加载'], ['confirmation', '待确认'], ['issue', '失败或阻塞']].map(([key, label]) => `<button data-action="filter" data-filter="${key}" aria-pressed="${key === activeFilter}" ${key === 'confirmation' && unavailable() ? 'disabled' : ''}>${label}</button>`).join('')}</div>${shown.map(group => workCard(group, workLink(group, 'chat', '进入对话'))).join('') || '<div class="card empty-state">当前筛选下没有可展示的工作。</div>'}<p class="footer-note">${scenario === 'truncated' ? '示例列表尚有下一页。' : ''}共展示 ${shown.length} 个已加载工作；此筛选范围不代表全量工作。</p>`);
}

function detailOverview(group) {
  return `<div class="detail-grid"><section class="card"><h2>当前目标</h2><p>${escapeHtml(group.goal)}</p><p>当前任务：${escapeHtml(group.current)}</p><progress value="${group.completed}" max="${group.tasks.length}" aria-label="任务进度"></progress><p class="meta">${group.completed}/${group.tasks.length} 项已完成 · 来自目标任务快照</p><div class="actions">${workLink(group, 'tasks', '查看完整任务')}</div></section>
    <section class="card"><h2>需要我处理</h2><p>${pendingOf(group) === null ? '待确认状态未知' : `${scenario === 'truncated' ? '至少 ' : ''}${pendingOf(group)} 项待确认`}</p><p>${problemsOf(group).map(task => escapeHtml(`${task[1]}：${task[0]}`)).join('<br>') || '当前快照未见失败或阻塞任务'}</p><div class="actions">${routeLink('attention', '查看待确认')}</div></section>
    <section class="card"><h2>交付物</h2><p>${group.localFiles === null ? '本地暂无同步记录' : `本地记录：已同步 ${group.localFiles} 个文件`}</p><div class="actions">${workLink(group, 'files', '查看远端文件')}</div></section>
    <section class="card"><h2>对话与执行上下文</h2><p>需要补充要求或追溯执行过程时，在对话中继续。</p><div class="actions">${workLink(group, 'chat', '进入对话')}</div></section></div>`;
}

function taskPanel(group) {
  return `<section class="card"><h2>目标任务</h2><p class="meta">展示现有任务状态；原型不模拟勾选完成或自动重试。</p><ol class="task-list">${group.tasks.map(([title, status]) => `<li>${tag(status, status === '失败')} <strong>${escapeHtml(title)}</strong>${['失败', '阻塞'].includes(status) ? `<div class="actions">${workLink(group, 'chat', '查看执行上下文')}</div>` : ''}</li>`).join('')}</ol></section>`;
}

function chatPanel(group, anchor) {
  const threads = groups().map(item =>
    `<a href="#work/${item.id}/chat" ${item.id === group.id ? 'aria-current="true"' : ''}>${escapeHtml(item.title)}</a>`
  ).join('');
  return '<div class="context-layout"><nav class="context-nav" aria-label="切换对话"><h2>已加载的对话</h2>'
    + threads + '</nav>' + chatMessages(group, anchor) + '</div>';
}

function chatMessages(group, anchor) {
  const confirmation = confirmations().find(item => item.group === group.id && (!anchor || item.turn === anchor));
  return `<section class="chat-log" aria-label="对话示例"><p class="meta">${anchor ? '已定位到待确认事项所属轮次 · 示例' : '执行上下文 · 示例片段'}</p><article class="card user"><h2>我的需求</h2><p>${escapeHtml(group.goal)}</p></article><article class="card"><h2>Agent</h2><p>已完成 ${group.completed} 项任务。当前任务：${escapeHtml(group.current)}。</p>${problemsOf(group).length ? '<p>请结合任务状态与执行记录查看具体原因。</p>' : ''}</article>${confirmation && !unavailable() ? `<article class="card attention-card"><h2>需要确认</h2><p>${escapeHtml(confirmation.reason)}</p><button data-action="confirmation" data-id="${confirmation.id}">查看确认</button></article>` : ''}<p class="footer-note">此处用于评审从工作、任务与确认事项回到对话的路径。完整消息输入仍由既有对话页承接。</p></section>`;
}

function filePanel(group) {
  if (scenario === 'offline') return '<section class="card"><h2>远端文件清单暂不可用</h2><p>首页的本地同步记录不能作为完整清单。恢复连接后可按工作查看远端文件。</p></section>';
  filePreviewCount++;
  return `<section class="card"><h2>交付物清单</h2><p class="meta">已打开当前工作的文件清单 · 示例数据；首页未预取其他工作的远端文件。</p>${group.files.length ? `<ul class="file-list">${group.files.map((file, index) => `<li><span class="file-name">${escapeHtml(file.name)}</span><p class="meta">${file.local ? '有本地同步记录；实际打开前仍需检查文件是否存在' : '远端文件 · 本地暂无同步记录'}</p><div class="actions"><button data-action="preview" data-group="${group.id}" data-index="${index}">预览</button></div></li>`).join('')}</ul>` : '<div class="empty-state"><h3>当前清单没有交付物</h3><p class="muted">文件清单已读取；这与“尚未读取”是不同状态。</p></div>'}</section>`;
}

function workPage(id, tab, anchor) {
  const group = groupOf(id);
  if (!group) return pageHeading('当前工作不可用', '示例数据已切换，或此原型路径不存在。') + routeLink('overview', '返回工作概览');
  const allowed = ['overview', 'tasks', 'chat', 'files'];
  const selected = allowed.includes(tab) ? tab : 'overview';
  return '<a class="back-link" href="#overview">返回工作概览</a>' + pageHeading(group.title, '目标与成果保持可见，需要沟通时进入对话。') + notice() + `<nav class="tabs" aria-label="工作详情分区">${[['overview', '概览'], ['tasks', '任务'], ['chat', '对话'], ['files', '交付物']].map(([key, label]) => `<a class="button" href="#work/${group.id}/${key}" ${key === selected ? 'aria-current="page"' : ''}>${label}</a>`).join('')}</nav>` + (scenario === 'loading' ? loadingBody() : selected === 'tasks' ? taskPanel(group) : selected === 'chat' ? chatPanel(group, anchor) : selected === 'files' ? filePanel(group) : detailOverview(group));
}

function morePage() {
  return pageHeading('更多', '跨工作配置与管理入口。') + `<div class="more-grid">${[
    ['习惯与自动执行', '保留习惯管理、执行历史与对话内执行计划的既有入口；本次不重做这些页面。'],
    ['记忆', '管理已有的事实、偏好与状态；不增加手动新建能力。'],
    ['设置', '保留外观、账号、交付物同步与本地清理等配置。'],
  ].map(([title, description]) => `<section class="card"><h2>${title}</h2><p>${description}</p><p class="meta">现有功能入口位置示意</p></section>`).join('')}</div><div class="notice" style="margin-top:24px"><strong>本次原型的评审范围</strong><p>概览、任务、确认事项、交付物与对话的查找路径。这里的辅助页面仅标注位置，不模拟现有完整功能。</p></div>`;
}

function render({ restore = false, focus = true } = {}) {
  const route = location.hash.slice(1) || 'overview';
  const [page, part, tab, anchor] = route.split('/');
  const inChat = page === 'conversations' || (page === 'work' && tab === 'chat');
  document.title = `${inChat ? '对话' : page === 'more' ? '更多' : '工作概览'} · Super PartyB 原型`;
  document.querySelectorAll('[data-nav]').forEach(link => {
    if (link.dataset.nav === (inChat ? 'conversations' : page === 'more' ? 'more' : 'overview')) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  });
  main.setAttribute('aria-busy', String(scenario === 'loading'));
  main.innerHTML = page === 'overview' ? overview() : page === 'attention' ? attentionPage() : page === 'issues' ? issuesPage() : page === 'conversations' ? conversationsPage() : page === 'work' ? workPage(part, tab, anchor) : page === 'more' ? morePage() : pageHeading('未找到原型页面', '请选择工作概览继续。') + routeLink('overview', '返回工作概览');
  if (focus) main.querySelector('h1')?.focus({ preventScroll: true });
  if (page === 'overview' && ['attention', 'current', 'deliverables'].includes(part)) {
    const section = document.getElementById(part);
    section?.querySelector('h2')?.focus({ preventScroll: true });
    section?.scrollIntoView({ block: 'start' });
  } else if (restore) window.scrollTo(0, scrollPositions.get(route) ?? 0);
  lastRoute = route;
}

function announce(message) { announcement.textContent = message; }

function openDialog(title, body, mode = '') {
  dialog.className = mode;
  document.querySelector('#dialog-title').textContent = title;
  document.querySelector('#dialog-body').innerHTML = body;
  if (!dialog.open) dialog.showModal();
}

document.querySelector('#close-dialog').addEventListener('click', () => dialog.close());
document.querySelector('.skip-link').addEventListener('click', event => {
  event.preventDefault();
  main.focus({ preventScroll: true });
  main.scrollIntoView({ block: 'start' });
});
// 导航可能随字号换行，锚点和键盘焦点需要避开实际占用的高度。
const appNav = document.querySelector('.app-nav');
const updateNavigationInset = () => {
  const compact = matchMedia('(max-width: 719px)').matches;
  const height = appNav.getBoundingClientRect().height;
  document.documentElement.style.setProperty('--nav-height', `${compact ? height : 0}px`);
  document.documentElement.style.setProperty('--top-nav-height', `${compact ? 0 : height}px`);
};
new ResizeObserver(updateNavigationInset).observe(appNav);
window.addEventListener('resize', updateNavigationInset);
updateNavigationInset();
document.querySelector('#theme').addEventListener('click', event => {
  const dark = document.documentElement.dataset.theme !== 'dark';
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  event.currentTarget.setAttribute('aria-pressed', String(dark));
});
scenarioSelect.addEventListener('change', () => {
  scenario = scenarioSelect.value;
  resolved.clear();
  activeFilter = 'all';
  render({ focus: false });
  announce(`已切换为${scenarioSelect.selectedOptions[0].textContent}示例。`);
});
window.addEventListener('hashchange', () => {
  scrollPositions.set(lastRoute, window.scrollY);
  if (dialog.open) dialog.close();
  render({ restore: true });
});

document.addEventListener('click', event => {
  const button = event.target.closest('button[data-action]');
  if (!button) return;
  const { action, id } = button.dataset;
  if (action === 'retry') {
    scenario = 'normal';
    scenarioSelect.value = scenario;
    render();
    announce('示例重试完成，待确认信息已恢复。');
  } else if (action === 'filter') {
    activeFilter = button.dataset.filter;
    render({ focus: false });
    const replacement = main.querySelector(`[data-filter="${activeFilter}"]`);
    replacement?.focus();
    announce(`已切换对话筛选：${replacement?.textContent}。`);
  } else if (action === 'confirmation') {
    const item = confirmations().find(item => item.id === id);
    if (!item || unavailable()) return;
    openDialog('待确认事项', `<p class="meta">${escapeHtml(groupOf(item.group).title)} · ${escapeHtml(item.expiry)}</p><p>${escapeHtml(item.reason)}</p><p class="meta">仅演示本地交互；不会发送确认决定，也不推断任务已恢复。</p><div class="actions"><button class="primary" data-action="resolve" data-id="${item.id}">演示继续</button>${routeLink(`work/${item.group}/chat/${item.turn}`, '先查看上下文')}</div>`);
  } else if (action === 'resolve') {
    resolved.add(id);
    dialog.close();
    render();
    announce('已在原型中移除此待确认项。未向服务端提交，任务进度保持原快照。');
  } else if (action === 'preview') {
    const group = groupOf(button.dataset.group);
    const file = group?.files[Number(button.dataset.index)];
    if (!file) return;
    const switching = dialog.open;
    const files = group.files.map((entry, index) =>
      `<button data-action="preview" data-group="${group.id}" data-index="${index}" ${entry === file ? 'aria-current="true"' : ''}>${escapeHtml(entry.name)}</button>`
    ).join('');
    const listing = group.files.length > 1
      ? `<nav class="context-nav" aria-label="切换文件"><h3>工作文件</h3>${files}</nav>` : '';
    openDialog(file.name,
      `<div class="${listing ? 'context-layout' : ''}">${listing}<div><p class="meta">只读预览</p><div class="preview-document">${escapeHtml(file.text)}</div></div></div>`,
      'file-preview');
    if (switching) dialog.querySelector('[aria-current="true"]')?.focus();
  } else if (action === 'capture') {
    openDialog('快速对话', '<form id="capture-form"><label for="capture-input">想让 Agent 做什么？</label><textarea id="capture-input" required placeholder="例如：整理本周资料，列出需要我确认的事项"></textarea><p class="meta">仅演示入口与反馈；不会发送消息、上传附件或创建工作。</p><div class="actions"><button class="primary" type="submit">演示提交</button></div></form>');
    document.querySelector('#capture-input').focus();
  }
});

document.addEventListener('submit', event => {
  if (event.target.id !== 'capture-form') return;
  event.preventDefault();
  const input = document.querySelector('#capture-input');
  if (!input.value.trim()) {
    input.setCustomValidity('请输入需求，不能只输入空格。');
    input.reportValidity();
    return;
  }
  openCaptureResult(input.value);
});
document.addEventListener('input', event => {
  if (event.target.id === 'capture-input') event.target.setCustomValidity('');
});

function openCaptureResult(value) {
  document.querySelector('#dialog-title').textContent = '演示提交完成';
  document.querySelector('#dialog-body').innerHTML = `<p>需求已在原型中接收，未发送到服务端。</p><div class="preview-document">${escapeHtml(value.trim())}</div><p class="meta">真实客户端继续使用现有快速对话入口与投递流程。</p>`;
  document.querySelector('#close-dialog').focus();
}

// 仅供离屏验证确认：首屏没有预取各工作的远端文件。
window.prototypeDiagnostics = () => ({ filePanelVisits: filePreviewCount, scenario });
history.scrollRestoration = 'manual';
render({ focus: false });

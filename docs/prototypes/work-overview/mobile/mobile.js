'use strict';

const screen = document.querySelector('#screen');
const nav = document.querySelector('#nav');
const sheet = document.querySelector('dialog');
const answered = new Map();
const groupById = new Map(sampleGroups.map(group => [group.id, group]));
const symbols = { home: 'efa1', chat: 'e155', more: 'e402', edit: 'f00d', clock: 'e556', problem: 'e238',
  right: 'e355', work: 'e6f4', folder: 'f090', file: 'efae', tasks: 'e646', confirm: 'e485' };
const tabs = [['home', '工作概览'], ['chat', '对话'], ['more', '更多']];
let draft = '';
let noticeTimer;

function icon(name, extra = '') {
  return `<i aria-hidden="true" class="${extra}">&#x${symbols[name]};</i>`;
}
function title(text, quick = false) {
  return `<div class="title"><h1>${text}</h1>${quick ? `<button class="action" data-sheet="capture">${icon('edit')}快速对话</button>` : ''}</div>`;
}
function sectionHeading(text, route, linkText) {
  return `<div class="section-title"><h2>${text}</h2><a class="more" href="#${route}">${linkText}${icon('right')}</a></div>`;
}
function row(path, heading, caption, symbol, suffix = '') {
  return `<a class="item" href="#${path}"><span class="item-icon ${symbol}">${icon(symbol)}</span>
    <span class="copy"><strong>${heading}</strong><small>${caption}</small></span>${suffix}${icon('right','chevron')}</a>`;
}
function workRow(group) {
  const ratio = `${group.completed}/${group.tasks.length}`;
  return row('work/' + group.id, group.title, group.current, 'work',
    `<span class="progress"><progress value="${group.completed}" max="${group.tasks.length}" aria-label="任务进度"></progress>${ratio}</span>`);
}
function confirmationCard(item) {
  const group = groupById.get(item.group);
  return `<a class="issue urgent" href="#${currentPath()}?sheet=${item.id}">
    <div class="card-top"><span class="chip">${icon('confirm')}待确认</span><span class="expiry">${icon('clock')}${item.expiry}</span></div>
    <p>${item.reason}</p><small>${group.title}</small></a>`;
}
function problemCards() {
  return sampleGroups.flatMap(group => group.tasks.flatMap(([label, status], index) => {
    if (!['失败','阻塞'].includes(status)) return [];
    return [`<a class="issue" href="#tasks/${group.id}/${index}"><div class="card-top"><span class="chip ${status === '失败' ? 'failure' : 'blocked'}">${icon('problem')}任务${status}</span><small>${group.title}</small></div>
      <div class="between"><strong>${label}</strong>${icon('right','chevron')}</div></a>`];
  }));
}
function pending() { return sampleConfirmations.filter(item => !answered.has(item.id)); }

function home() {
  return title('工作概览', true) + '<section>' + sectionHeading('待你处理','inbox','查看全部')
    + pending().slice(0,1).map(confirmationCard).join('') + problemCards()[0] + '</section><section>'
    + sectionHeading('当前工作','works','全部工作') + sampleGroups.slice(0,2).map(workRow).join('')
    + '</section><section>' + row('files','交付物','按工作浏览文件','folder') + '</section>';
}
function inbox() {
  return title('待你处理') + `<section><h2>待确认 · ${pending().length}</h2>${pending().map(confirmationCard).join('') || '<p class="lead">当前没有待确认事项。</p>'}</section>
    <section><h2>失败与阻塞</h2>${problemCards().join('')}</section>`;
}
function fileIndex() {
  return title('交付物') + sampleGroups.map(group => row('files/' + group.id, group.title,
    group.localFiles ? `本地已同步 ${group.localFiles} 个文件` : '本地暂无同步记录', 'folder')).join('');
}
function details(page, group, index) {
  const related = sampleConfirmations.find(item => item.group === group.id);
  switch (page) {
    case 'work':
      return title(group.title) + `<p class="lead">${group.goal}</p><section><h2>当前任务</h2>
        <p>${group.current}</p><small>${group.completed}/${group.tasks.length} 项已完成</small></section><section>`
        + row('tasks/' + group.id,'任务清单',`${group.tasks.length} 项任务`,'tasks')
        + row('files/' + group.id,'交付物','浏览工作文件','folder')
        + row('thread/' + group.id,'对话','查看执行上下文','chat') + '</section>';
    case 'tasks':
      return title('任务清单') + `<p class="lead">${group.title} · ${group.completed}/${group.tasks.length} 项已完成</p><section>`
        + group.tasks.map(([name, status], n) => `<div class="task ${String(n) === index ? 'target' : ''}" id="task-${n}"><strong>${name}</strong><small>${status}</small>
          ${['失败','阻塞'].includes(status) ? `<a class="action" href="#thread/${group.id}">查看执行上下文${icon('right')}</a>` : ''}</div>`).join('') + '</section>';
    case 'thread': {
      const turn = related && (!index || index === related.turn) ? related : null;
      return title(group.title) + `<p class="lead">对话${turn ? ' · 第 '+turn.turn.split('-')[1]+' 轮' : ''}</p>
        <article class="message"><h2>我的需求</h2><p>${group.goal}</p></article>
        <article class="message"><h2>Agent</h2><p>已完成 ${group.completed} 项任务。当前任务是${group.current}。</p></article>`
        + (turn ? `<article class="message target"><h2>${answered.get(turn.id) || '待确认'}</h2><p>${turn.reason}</p>
          ${answered.has(turn.id) ? '' : `<button class="action" data-sheet="${turn.id}">查看确认</button>`}</article>` : '');
    }
    case 'files':
      return title(group.title) + '<p class="lead">交付物</p><section>' + (group.files.map((file, n) =>
        row('preview/'+group.id+'/'+n, file.name.split('/').pop(), file.local ? '有本地同步记录' : '远端文件 · 本地暂无同步记录','file')).join('') || '<p>当前清单没有交付物。</p>') + '</section>';
    case 'preview': {
      const file = group.files.find((_, n) => String(n) === index);
      if (file) return title(file.name.split('/').pop()) + `<p class="lead">${group.title} · 文件预览</p><article class="document">${file.text}</article>`;
      break;
    }
  }
  return title('未找到此页面') + '<a class="action" href="#home">返回工作概览</a>';
}
function currentPath() { return location.hash.slice(1).split('?')[0] || 'home'; }
function pageContent(path) {
  switch (path) {
    case 'home': return home();
    case 'inbox': return inbox();
    case 'works': return title('当前工作') + sampleGroups.map(workRow).join('');
    case 'files': return fileIndex();
    case 'chat': return title('对话', true) + sampleGroups.map(g => row('thread/'+g.id, g.title, g.current,'chat')).join('');
    case 'more': return title('更多') + '<section><h2>原型评审</h2><a class="item" href="../index.html">打开桌面与移动对照原型</a><button class="item" data-reset>重置演示数据</button></section>';
  }
  const [page, id, index] = path.split('/');
  return groupById.has(id) ? details(page, groupById.get(id), index) : title('未找到此页面') + '<a class="action" href="#home">返回工作概览</a>';
}

function renderSheet(id) {
  const heading = document.querySelector('#sheet-title');
  const content = document.querySelector('#sheet-body');
  if (id === 'capture') {
    heading.textContent = '快速对话';
    content.innerHTML = '<form><label for="request">想让 Agent 做什么？</label><textarea id="request" rows="4" required></textarea><div class="sheet-buttons"><button class="solid" type="submit">演示提交</button></div></form>';
    content.querySelector('textarea').value = draft;
  } else {
    const item = sampleConfirmations.find(c => c.id === id);
    if (!item) return;
    heading.textContent = answered.get(id) || '待确认';
    content.innerHTML = `<small>${groupById.get(item.group).title} · ${item.expiry}</small><p class="lead">${item.reason}</p>
      <a class="action" href="#thread/${item.group}/${item.turn}">查看所属轮次${icon('right')}</a>
      ${answered.has(id) ? '' : '<div class="sheet-buttons"><button class="solid" data-answer="已同意继续">同意继续</button><button class="secondary" data-answer="已拒绝继续">拒绝继续</button></div>'}`;
  }
  sheet.showModal();
}
function sheetId() { return new URLSearchParams(location.hash.split('?')[1]).get('sheet'); }
function rememberPosition() {
  const focused = document.activeElement;
  const links = [...screen.querySelectorAll('a,button')];
  history.replaceState({...history.state, y: screen.scrollTop, focus: links.indexOf(focused)}, '');
}
function go(hash) {
  rememberPosition();
  history.pushState({ mobile: true }, '', hash);
  render();
}
function back() {
  if (history.state?.mobile) history.back();
  else {
    location.replace(sheet.open ? '#'+currentPath() : '#home');
  }
}
function render() {
  if (sheet.open) sheet.close();
  const path = currentPath();
  const isTab = tabs.some(([key]) => key === path);
  nav.hidden = !isTab;
  nav.innerHTML = tabs.map(([key, label]) => `<a href="#${key}" ${path === key ? 'aria-current="page"' : ''}>${icon(key)}${label}</a>`).join('');
  screen.innerHTML = (isTab ? '' : '<button class="back" data-back>‹ 返回</button>') + pageContent(path);
  const heading = screen.querySelector('h1');
  document.title = heading.textContent + ' · Super PartyB 移动草稿';
  const state = history.state || {};
  const focusTarget = screen.querySelectorAll('a,button')[state.focus] || screen;
  focusTarget.focus({preventScroll:true});
  screen.scrollTop = state.y || 0;
  const selected = screen.querySelector('.task.target');
  if (selected && state.y == null) selected.scrollIntoView({block:'center'});
  if (sheetId()) renderSheet(sheetId());
}
function announce(message) {
  const feedback = document.querySelector('#feedback');
  feedback.textContent = message;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => feedback.textContent = '', 2200);
}
document.addEventListener('click', event => {
  const link = event.target.closest('a[href^="#"]');
  if (link && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey) {
    event.preventDefault();
    if (link.hash !== location.hash) go(link.hash);
    return;
  }
  const button = event.target.closest('button');
  if (!button) return;
  if (button.hasAttribute('data-back')) back();
  if (button.dataset.sheet) go('#'+currentPath()+'?sheet='+button.dataset.sheet);
  if (button.dataset.answer && sheet.open) {
    answered.set(sheetId(), button.dataset.answer);
    announce('此确认项已处理');
    back();
  }
  if (button.hasAttribute('data-reset')) {
    answered.clear();
    draft = '';
    announce('演示数据已重置');
  }
});
sheet.addEventListener('cancel', event => { event.preventDefault(); back(); });
sheet.addEventListener('input', event => {
  if (event.target.id === 'request') {
    draft = event.target.value;
    event.target.setCustomValidity('');
  }
});
sheet.addEventListener('submit', event => {
  event.preventDefault();
  if (!draft.trim()) {
    const field = sheet.querySelector('textarea');
    field.setCustomValidity('请输入需求');
    field.reportValidity();
    return;
  }
  draft = '';
  announce('演示提交完成');
  back();
});
window.addEventListener('popstate', render);
render();

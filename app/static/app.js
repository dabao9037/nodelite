const $ = selector => document.querySelector(selector);
const baseUrl = new URL('./', document.baseURI);
const appUrl = path => new URL(String(path).replace(/^\/+/, ''), baseUrl).toString();
let nodes = [];
let telemetryTimer;

const esc = value => String(value).replace(/[&<>"']/g, character => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
})[character]);

async function api(path, options = {}) {
  const response = await fetch(appUrl(path), {
    ...options,
    headers: {'Content-Type': 'application/json', ...(options.headers || {})}
  });
  if (response.status === 204) return null;
  const data = await response.json().catch(() => ({detail: '请求失败'}));
  if (!response.ok) throw Error(data.detail || '请求失败');
  return data;
}

function protocolLabel(protocol) {
  return protocol === 'socks' ? 'SOCKS' : protocol === 'shadowsocks' ? 'SS-2022' : 'VLESS REALITY';
}

function bytes(value, rate = false) {
  const number = Math.max(0, Number(value) || 0);
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let index = 0;
  let current = number;
  while (current >= 1024 && index < units.length - 1) { current /= 1024; index += 1; }
  const precision = current >= 100 || index === 0 ? 0 : current >= 10 ? 1 : 2;
  return `${current.toFixed(precision)} ${units[index]}${rate ? '/s' : ''}`;
}

function expiryText(node) {
  if (!node.expires_at) return '永不过期';
  if (node.expired) return '已到期';
  const seconds = Math.max(0, node.remaining_seconds || 0);
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  if (days) return `${days}天 ${hours}小时后到期`;
  const minutes = Math.max(1, Math.floor(seconds / 60));
  return `${hours}小时 ${minutes % 60}分钟后到期`;
}

function statusLabel(node) {
  if (node.expired) return 'EXPIRED';
  return node.enabled ? 'ACTIVE' : 'DISABLED';
}

function render() {
  $('#empty').hidden = nodes.length > 0;
  $('#list').innerHTML = nodes.map(node => `
    <article class="node-card ${node.enabled ? '' : 'disabled'} ${node.expired ? 'expired' : ''}" data-node-id="${node.id}">
      <div class="node-head">
        <div><h3>${esc(node.name)}</h3><span class="tag">${protocolLabel(node.protocol)}</span></div>
        <span class="status status-${esc(node.status)}">${statusLabel(node)}</span>
      </div>
      <div class="node-meta">
        <div class="port"><strong>${node.port}</strong><small>PORT</small></div>
        <div><strong data-connection-value>${node.active_connections}</strong><small>连接 / ${node.max_connections || '不限'}</small></div>
        <div><strong data-expiry-value>${esc(expiryText(node))}</strong><small>有效期</small></div>
      </div>
      <div class="metrics">
        <div><span>↑ 入站累计</span><strong data-uplink-total>${bytes(node.traffic_uplink)}</strong><small data-uplink-rate>${bytes(node.uplink_rate, true)}</small></div>
        <div><span>↓ 出站累计</span><strong data-downlink-total>${bytes(node.traffic_downlink)}</strong><small data-downlink-rate>${bytes(node.downlink_rate, true)}</small></div>
      </div>
      <div class="link"><input readonly aria-label="${esc(node.name)} 分享链接" value="${esc(node.link)}"><button type="button" data-copy="${esc(node.link)}">复制</button></div>
      <img class="qr" src="${esc(appUrl(node.qr))}" alt="${esc(node.name)} 节点二维码" loading="lazy">
      <div class="actions"><button type="button" data-edit="${node.id}">编辑</button><button type="button" data-toggle="${node.id}" ${node.expired ? 'disabled title="请先编辑有效期"' : ''}>${node.enabled ? '停用' : '启用'}</button><button type="button" data-delete="${node.id}">删除</button></div>
    </article>
  `).join('');
}

async function load() {
  nodes = await api('api/nodes');
  render();
}

async function refreshTelemetry() {
  const values = await api('api/nodes/telemetry');
  const byId = new Map(values.map(item => [item.id, item]));
  let structuralChange = false;
  nodes = nodes.map(node => {
    const next = byId.get(node.id);
    if (!next) return node;
    if (node.status !== next.status || node.enabled !== (next.status === 'active') || node.expired !== next.expired) structuralChange = true;
    return {...node, ...next, enabled: next.status === 'active'};
  });
  if (structuralChange) { render(); return; }
  nodes.forEach(node => {
    const card = document.querySelector(`[data-node-id="${node.id}"]`);
    if (!card) return;
    card.querySelector('[data-uplink-total]').textContent = bytes(node.traffic_uplink);
    card.querySelector('[data-downlink-total]').textContent = bytes(node.traffic_downlink);
    card.querySelector('[data-uplink-rate]').textContent = bytes(node.uplink_rate, true);
    card.querySelector('[data-downlink-rate]').textContent = bytes(node.downlink_rate, true);
    card.querySelector('[data-connection-value]').textContent = node.active_connections;
    card.querySelector('[data-expiry-value]').textContent = expiryText(node);
  });
}

function showError(error) {
  $('#error').textContent = error.message || String(error);
  $('#error').hidden = false;
}

function bindExpiration(modeSelector, dateField, daysField) {
  const update = () => {
    const mode = $(modeSelector).value;
    $(dateField).hidden = mode !== 'date';
    $(daysField).hidden = mode !== 'days';
  };
  $(modeSelector).addEventListener('change', update);
  update();
}

function expirationPayload(prefix = '') {
  const cap = value => prefix ? value.charAt(0).toUpperCase() + value.slice(1) : value;
  const mode = $(`#${prefix}${cap('expirationMode')}`).value;
  const payload = {expiration_mode: mode};
  if (mode === 'date') {
    const value = $(`#${prefix}${cap('expiresAt')}`).value;
    if (!value) throw Error('请选择到期日期');
    payload.expires_at = new Date(value).toISOString();
  } else if (mode === 'days') {
    payload.expires_in_days = Number($(`#${prefix}${cap('expiresInDays')}`).value);
  }
  return payload;
}

function localDateTime(epoch) {
  if (!epoch) return '';
  const date = new Date(epoch * 1000);
  const shifted = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return shifted.toISOString().slice(0, 16);
}

const REALITY_PRESETS = new Set([
  'www.apple.com', 'www.amazon.com', 'www.cloudflare.com',
  'addons.mozilla.org', 'www.bing.com', 'www.google.com'
]);

function updateRealityPreset() {
  const value = $('#realityPreset').value;
  const custom = value === 'custom';
  document.querySelectorAll('.reality-custom-field').forEach(item => {
    item.dataset.customVisible = custom ? '1' : '0';
    item.hidden = !custom || $('#protocol').value !== 'vless';
  });
  if (!custom) {
    $('#serverName').value = value;
    $('#destination').value = `${value}:443`;
  }
}

document.querySelectorAll('.protocol').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelectorAll('.protocol').forEach(item => item.classList.remove('active'));
    button.classList.add('active');
    const protocol = button.dataset.proto;
    $('#protocol').value = protocol;
    document.querySelectorAll('.socks-field').forEach(item => item.hidden = protocol !== 'socks');
    document.querySelectorAll('.ss-field').forEach(item => item.hidden = protocol !== 'shadowsocks');
    document.querySelectorAll('.vless-field').forEach(item => item.hidden = protocol !== 'vless');
    if (protocol === 'vless') updateRealityPreset();
    else document.querySelectorAll('.reality-custom-field').forEach(item => item.hidden = true);
  });
});

$('#realityPreset').addEventListener('change', updateRealityPreset);
$('#serverName').addEventListener('input', () => {
  if ($('#realityPreset').value === 'custom' && !$('#destination').dataset.touched) {
    $('#destination').value = $('#serverName').value ? `${$('#serverName').value}:443` : '';
  }
});
$('#destination').addEventListener('input', () => { $('#destination').dataset.touched = '1'; });

bindExpiration('#expirationMode', '#expirationDateField', '#expirationDaysField');
bindExpiration('#editExpirationMode', '#editExpirationDateField', '#editExpirationDaysField');

$('#createForm').addEventListener('submit', async event => {
  event.preventDefault();
  $('#error').hidden = true;
  try {
    const protocol = $('#protocol').value;
    const body = {
      name: $('#name').value, protocol,
      port: $('#port').value ? Number($('#port').value) : null,
      max_connections: $('#maxConnections').value ? Number($('#maxConnections').value) : null,
      ...expirationPayload()
    };
    if (protocol === 'socks') {
      body.username = $('#username').value || null;
      body.password = $('#password').value || null;
    } else if (protocol === 'shadowsocks') {
      body.password = $('#ssPassword').value || null;
    } else {
      body.server_name = $('#serverName').value;
      body.destination = $('#destination').value;
    }
    await api('api/nodes', {method: 'POST', body: JSON.stringify(body)});
    event.target.reset();
    $('#protocol').value = protocol;
    $('#expirationMode').dispatchEvent(new Event('change'));
    await load();
  } catch (error) { showError(error); }
});

$('#list').addEventListener('click', async event => {
  const copy = event.target.closest('[data-copy]');
  const edit = event.target.closest('[data-edit]');
  const toggle = event.target.closest('[data-toggle]');
  const remove = event.target.closest('[data-delete]');
  try {
    if (copy) {
      await navigator.clipboard.writeText(copy.dataset.copy);
      copy.textContent = '已复制';
      setTimeout(() => copy.textContent = '复制', 1000);
    } else if (edit) {
      const node = nodes.find(item => item.id === Number(edit.dataset.edit));
      $('#editId').value = node.id;
      $('#editName').value = node.name;
      $('#editMaxConnections').value = node.max_connections || '';
      $('#editExpirationMode').value = node.expires_at ? 'date' : 'never';
      $('#editExpiresAt').value = localDateTime(node.expires_at);
      $('#editExpirationMode').dispatchEvent(new Event('change'));
      $('#editDialog').showModal();
    } else if (toggle) {
      await api(`api/nodes/${toggle.dataset.toggle}/toggle`, {method: 'POST'});
      await load();
    } else if (remove && confirm('确定删除这个节点吗？')) {
      await api(`api/nodes/${remove.dataset.delete}`, {method: 'DELETE'});
      await load();
    }
  } catch (error) { showError(error); }
});

$('#editCancel').addEventListener('click', () => $('#editDialog').close());
$('#editForm').addEventListener('submit', async event => {
  event.preventDefault();
  try {
    const body = {
      name: $('#editName').value,
      max_connections: $('#editMaxConnections').value ? Number($('#editMaxConnections').value) : null,
      ...expirationPayload('edit')
    };
    await api(`api/nodes/${$('#editId').value}`, {method: 'PUT', body: JSON.stringify(body)});
    $('#editDialog').close();
    await load();
  } catch (error) { showError(error); }
});

$('#refresh').addEventListener('click', () => load().catch(showError));
load().then(() => {
  telemetryTimer = setInterval(() => refreshTelemetry().catch(showError), 2000);
}).catch(showError);
window.addEventListener('beforeunload', () => clearInterval(telemetryTimer));

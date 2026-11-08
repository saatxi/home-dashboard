// El rellotge és local; tota la resta ve de data/data.json, que genera el servidor.
// El marc no surt mai a internet: només parla amb el servidor que serveix aquesta pàgina.
var DATA_URL = 'data/data.json';
var REFRESH_MS = 30 * 1000;
var STALE_MS = 20 * 60 * 1000;
var MAX_EVENTS = 7;
var MAX_TASKS = 8;

var lastOk = null;
var data = null;

// Codis meteorològics WMO d'Open-Meteo.
var WEATHER = [
  [[0], 'Cel serè'], [[1, 2], 'Poc ennuvolat'], [[3], 'Ennuvolat'], [[45, 48], 'Boira'],
  [[51, 53, 55, 56, 57], 'Plugim'], [[61, 63, 65, 66, 67], 'Pluja'], [[71, 73, 75, 77, 85, 86], 'Neu'],
  [[80, 81, 82], 'Ruixats'], [[95, 96, 99], 'Tempesta']
];

function pad(n) { return n < 10 ? '0' + n : '' + n; }
function hhmm(d) { return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
function el(id) { return document.getElementById(id); }

function weatherText(code) {
  for (var i = 0; i < WEATHER.length; i++) {
    if (WEATHER[i][0].indexOf(code) !== -1) return WEATHER[i][1];
  }
  return '';
}

function node(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
}

function dayKey(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }

function dayLabel(d) {
  var today = new Date(); today.setHours(0, 0, 0, 0);
  var diff = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - today) / 86400000);
  if (diff === 0) return 'Avui';
  if (diff === 1) return 'Demà';
  return d.toLocaleDateString('ca', { weekday: 'long', day: 'numeric', month: 'long' });
}

function parseDay(s) { var p = s.split('-'); return new Date(+p[0], +p[1] - 1, +p[2]); }

function renderWeather() {
  var box = el('weather');
  box.textContent = '';
  var w = data && data.weather;
  if (!w) return;
  box.appendChild(node('div', 'wnow', Math.round(w.temperature) + '° · ' + weatherText(w.code)));
  box.appendChild(node('div', 'wplace', w.place));
  var days = node('div', 'wdays');
  for (var i = 1; i < w.days.length; i++) {
    var d = w.days[i], item = node('div', 'wday');
    item.appendChild(node('b', '', parseDay(d.date).toLocaleDateString('ca', { weekday: 'short' })));
    item.appendChild(document.createTextNode(Math.round(d.min) + '° / ' + Math.round(d.max) + '° ' + weatherText(d.code)));
    days.appendChild(item);
  }
  box.appendChild(days);
}

function renderEvents() {
  var list = el('events');
  list.textContent = '';
  var events = data && data.events;
  if (!events || !events.length) {
    list.appendChild(node('li', 'empty', events ? 'Res previst' : 'Sense dades'));
    return;
  }
  var now = new Date(), shown = 0, lastDay = '';
  for (var i = 0; i < events.length && shown < MAX_EVENTS; i++) {
    var e = events[i];
    var start = e.all_day ? parseDay(e.start) : new Date(e.start);
    var end = e.all_day ? parseDay(e.end) : new Date(e.end);
    if (!e.all_day && end < now) continue; // ja ha acabat
    var key = dayKey(start);
    if (key !== lastDay) { list.appendChild(node('li', 'day', dayLabel(start))); lastDay = key; }
    var li = node('li');
    li.appendChild(node('span', 'when', e.all_day ? 'Tot el dia' : hhmm(start)));
    li.appendChild(document.createTextNode(e.title));
    list.appendChild(li);
    shown++;
  }
  if (!shown) list.appendChild(node('li', 'empty', 'Res previst'));
}

function renderTasks() {
  var list = el('tasks');
  list.textContent = '';
  var tasks = data && data.tasks;
  if (!tasks || !tasks.length) { list.appendChild(node('li', 'empty', 'Cap tasca')); return; }
  var ordered = tasks.filter(function (t) { return !t.done; })
    .concat(tasks.filter(function (t) { return t.done; }));
  ordered.slice(0, MAX_TASKS).forEach(function (t) {
    list.appendChild(node('li', t.done ? 'done' : '', (t.done ? '✓ ' : '☐ ') + t.text));
  });
}

function renderStatus() {
  var status = el('status');
  if (lastOk === null) {
    status.textContent = 'sense dades del servidor';
    status.className = 'stale';
    return;
  }
  var errors = data && data.errors ? Object.keys(data.errors) : [];
  var stale = Date.now() - lastOk > STALE_MS || errors.length > 0;
  status.textContent = 'servidor ' + hhmm(new Date(lastOk)) + (errors.length ? ' · error: ' + errors.join(', ') : '');
  status.className = stale ? 'stale' : '';
}

function tickClock() {
  var now = new Date();
  el('time').textContent = hhmm(now);
  el('date').textContent =
    now.toLocaleDateString('ca', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  renderStatus();
}

function renderAll() {
  renderWeather();
  renderEvents();
  renderTasks();
  renderStatus();
}

function refreshData() {
  fetch(DATA_URL, { cache: 'no-store' })
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (json) { data = json; lastOk = Date.now(); renderAll(); })
    .catch(function () { renderStatus(); });
}

tickClock();
setInterval(tickClock, 1000);
setInterval(function () { if (data) renderEvents(); }, 60 * 1000);
refreshData();
setInterval(refreshData, REFRESH_MS);

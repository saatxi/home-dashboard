// El rellotge és local; tota la resta ve de data/data.json, que genera el servidor.
// El marc no surt mai a internet: només parla amb el servidor que serveix aquesta pàgina.
var DATA_URL = 'data/data.json';
var REFRESH_MS = 30 * 1000;
var STALE_MS = 20 * 60 * 1000;
// Antiguitat màxima de data.json (moment en què el servidor el va generar) abans de marcar-ho com a vell.
var GENERATED_STALE_MS = 25 * 60 * 1000;
var WEATHER_OLD_MS = 3 * 60 * 60 * 1000;
var FETCH_TIMEOUT_MS = 10 * 1000;
var MAX_EVENTS = 7;
var MAX_TASKS = 8;

var lastOk = null;
var data = null;
// Evita que una petició penjada s'acumuli amb les següents; reqId distingeix peticions velles de la vigent.
var inflight = false;
var reqId = 0;
// Seccions que no s'han pogut pintar (es mostren al peu).
var paintFailed = [];
// Zona horària de data.json (opcional); sense ella s'usa la del dispositiu.
var tz = null;
var tzFmt = null;
// Primera site_version que ha vist aquesta càrrega (hash del contingut de la pàgina, de data.json).
// Si més endavant el servidor en publica una altra, la pàgina ha canviat i es recarrega.
var pageVersion = null;
// El rellotge del marc no és fiable (el RTC es perd quan es talla la corrent). L'hora bona és la del
// servidor, que arriba a la capçalera Date de cada resposta de data.json.
var clockOffsetMs = 0;
var clockSynced = false;

// Codis meteorològics WMO d'Open-Meteo.
var WEATHER = [
  [[0], 'Cel serè'], [[1, 2], 'Poc ennuvolat'], [[3], 'Ennuvolat'], [[45, 48], 'Boira'],
  [[51, 53, 55, 56, 57], 'Plugim'], [[61, 63, 65, 66, 67], 'Pluja'], [[71, 73, 75, 77, 85, 86], 'Neu'],
  [[80, 81, 82], 'Ruixats'], [[95, 96, 99], 'Tempesta']
];

function nowDate() { return new Date(Date.now() + clockOffsetMs); }

function pad(n) { return n < 10 ? '0' + n : '' + n; }
function el(id) { return document.getElementById(id); }

function setZone(name) {
  name = name || null;
  if (name !== tz) { tz = name; tzFmt = null; }
}

// Any, mes, dia, hora i minut d'un Date a la zona de data.json (el marc pot tenir-ne una altra de configurada).
function zoneParts(d) {
  if (!tzFmt) {
    var o = { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false };
    if (tz) o.timeZone = tz;
    try { tzFmt = new Intl.DateTimeFormat('en-GB', o); }
    catch (e) { tz = null; delete o.timeZone; tzFmt = new Intl.DateTimeFormat('en-GB', o); } // zona desconeguda
  }
  var p = {};
  tzFmt.formatToParts(d).forEach(function (x) { p[x.type] = x.value; });
  return { y: +p.year, m: +p.month, d: +p.day, hh: +p.hour % 24, mm: +p.minute }; // algunes versions donen 24 a mitjanit
}

function hhmm(d) { var p = zoneParts(d); return pad(p.hh) + ':' + pad(p.mm); }

// Data d'un Date a la zona de data.json, com a clau "AAAA-MM-DD" (comparable com a text).
function dayKey(d) { var p = zoneParts(d); return p.y + '-' + pad(p.m) + '-' + pad(p.d); }

function dayNum(key) { var p = key.split('-'); return Date.UTC(+p[0], +p[1] - 1, +p[2]) / 86400000; }

function fmtDate(d, o) {
  if (tz) {
    o.timeZone = tz;
    try { return d.toLocaleDateString('ca', o); } catch (e) { tz = null; tzFmt = null; delete o.timeZone; }
  }
  return d.toLocaleDateString('ca', o);
}

// Dia sencer (AAAA-MM-DD) sense zona: es formata a migdia UTC perquè cap zona el canviï de dia.
function fmtDay(key, o) {
  var p = key.split('-');
  o.timeZone = 'UTC';
  return new Date(Date.UTC(+p[0], +p[1] - 1, +p[2], 12)).toLocaleDateString('ca', o);
}

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

function dayLabel(key) {
  var diff = dayNum(key) - dayNum(dayKey(nowDate()));
  if (diff === 0) return 'Avui';
  if (diff === 1) return 'Demà';
  return fmtDay(key, { weekday: 'long', day: 'numeric', month: 'long' });
}

function renderWeather() {
  var box = el('weather');
  box.textContent = '';
  box.className = '';
  var w = data && data.weather;
  if (!w) return;
  // Si el servidor fa estona que no refresca el temps (dades antigues de reserva), s'atenua.
  var wAt = data.fetched_at && Date.parse(data.fetched_at.weather);
  if (wAt && nowDate() - wAt > WEATHER_OLD_MS) box.className = 'old';
  box.appendChild(node('div', 'wnow', Math.round(w.temperature) + '° · ' + weatherText(w.code)));
  box.appendChild(node('div', 'wplace', w.place));
  var days = node('div', 'wdays');
  for (var i = 0; i < w.days.length; i++) {
    var d = w.days[i], item = node('div', 'wday');
    item.appendChild(node('b', '', i === 0 ? 'avui' : fmtDay(d.date, { weekday: 'short' })));
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
  var now = nowDate(), today = dayKey(now), visible = [];
  for (var i = 0; i < events.length; i++) {
    var e = events[i], key;
    if (e.all_day) {
      if ((e.end || e.start) < today) continue; // ja ha acabat (end inclusiu)
      key = e.start;
    } else {
      var start = new Date(e.start);
      if (new Date(e.end) < now) continue; // ja ha acabat
      key = dayKey(start);
    }
    if (key < today) key = today; // comença abans d'avui però encara dura: surt a "Avui"
    visible.push({ e: e, key: key, start: start });
  }
  var lastDay = '';
  visible.slice(0, MAX_EVENTS).forEach(function (v) {
    if (v.key !== lastDay) { list.appendChild(node('li', 'day', dayLabel(v.key))); lastDay = v.key; }
    var li = node('li');
    li.appendChild(node('span', 'when', v.e.all_day ? 'Tot el dia' : hhmm(v.start)));
    li.appendChild(document.createTextNode(v.e.title));
    list.appendChild(li);
  });
  if (!visible.length) list.appendChild(node('li', 'empty', 'Res previst'));
  else if (visible.length > MAX_EVENTS) list.appendChild(node('li', 'more', '+' + (visible.length - MAX_EVENTS) + ' més'));
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
  document.body.className = clockSynced ? '' : 'unverified';
  if (lastOk === null) {
    status.textContent = 'sense dades del servidor · hora sense verificar';
    status.className = 'stale';
    return;
  }
  var errors = data && data.errors ? Object.keys(data.errors) : [];
  // Es mostra l'edat de les dades (quan les va generar el servidor), no la de l'última petició.
  var generated = data && data.generated ? Date.parse(data.generated) : NaN;
  var stale = Date.now() - lastOk > STALE_MS || errors.length > 0 || paintFailed.length > 0;
  var shownAt;
  if (isNaN(generated)) shownAt = new Date(lastOk + clockOffsetMs);
  else { shownAt = new Date(generated); if (nowDate() - generated > GENERATED_STALE_MS) stale = true; }
  status.textContent = 'dades de ' + hhmm(shownAt) + (errors.length ? ' · error: ' + errors.join(', ') : '') +
    (paintFailed.length ? ' · error de pintat: ' + paintFailed.join(', ') : '');
  status.className = stale ? 'stale' : '';
}

function tickClock() {
  var now = nowDate();
  el('time').textContent = hhmm(now);
  el('date').textContent = fmtDate(now, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  renderStatus();
}

// Una secció que falla no ha d'aturar les altres: es recorda quina i es mostra al peu.
function paint(name, fn) {
  var at = paintFailed.indexOf(name);
  try { fn(); if (at !== -1) paintFailed.splice(at, 1); }
  catch (e) { if (at === -1) paintFailed.push(name); }
}

function renderAll() {
  paint('weather', renderWeather);
  paint('events', renderEvents);
  paint('tasks', renderTasks);
  tickClock(); // també repinta el rellotge, per si ha canviat la zona
}

// No pot entrar en bucle: després de recarregar, la primera versió vista ja és la nova.
function reloadIfPageChanged(json) {
  var seen = json && json.site_version ? String(json.site_version) : null;
  if (!seen) return;
  if (pageVersion === null) { pageVersion = seen; return; }
  if (seen !== pageVersion) location.reload();
}

function refreshData() {
  if (inflight) return; // una petició penjada no s'ha d'acumular amb les següents
  inflight = true;
  var id = ++reqId, ctl = typeof AbortController !== 'undefined' ? new AbortController() : null;
  function finish() { if (id === reqId) { inflight = false; clearTimeout(timer); } }
  // Si el servidor no respon, es talla als 10 s i s'allibera el senyalador encara que l'abort no arribi.
  var timer = setTimeout(function () { if (ctl) ctl.abort(); finish(); }, FETCH_TIMEOUT_MS);
  var req;
  try { req = fetch(DATA_URL, { cache: 'no-store', signal: ctl ? ctl.signal : undefined }); }
  catch (e) { req = Promise.reject(e); }
  req
    .then(function (r) {
      if (!r.ok) throw new Error(r.status);
      var serverTime = Date.parse(r.headers.get('Date'));
      if (!isNaN(serverTime)) { clockOffsetMs = serverTime - Date.now(); clockSynced = true; }
      return r.json();
    })
    .then(function (json) {
      data = json; lastOk = Date.now();
      setZone(json && json.timezone);
      try { reloadIfPageChanged(json); } catch (e) { /* no ha d'impedir pintar */ }
      renderAll();
    })
    .catch(function () { try { renderStatus(); } catch (e) { /* res més a fer */ } })
    .then(finish, finish);
}

tickClock();
setInterval(tickClock, 1000);
setInterval(function () { if (data) { paint('events', renderEvents); renderStatus(); } }, 60 * 1000);
refreshData();
setInterval(refreshData, REFRESH_MS);

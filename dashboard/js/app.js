// El rellotge és local; tota la resta ve de data/data.json, que genera el servidor.
// El marc no surt mai a internet: només parla amb el servidor que serveix aquesta pàgina.
var DATA_URL = 'data/data.json';
var REFRESH_MS = 30 * 1000;
var STALE_MS = 10 * 60 * 1000;

var lastOk = null;

function pad(n) { return n < 10 ? '0' + n : '' + n; }

function tickClock() {
  var now = new Date();
  document.getElementById('time').textContent = pad(now.getHours()) + ':' + pad(now.getMinutes());
  document.getElementById('date').textContent =
    now.toLocaleDateString('ca', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  renderStatus();
}

function renderStatus() {
  var el = document.getElementById('status');
  if (lastOk === null) {
    el.textContent = 'sense dades del servidor';
    el.className = 'stale';
    return;
  }
  var age = Date.now() - lastOk;
  var d = new Date(lastOk);
  el.textContent = 'servidor ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  el.className = age > STALE_MS ? 'stale' : '';
}

function refreshData() {
  fetch(DATA_URL, { cache: 'no-store' })
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function () { lastOk = Date.now(); renderStatus(); })
    .catch(function () { renderStatus(); });
}

tickClock();
setInterval(tickClock, 1000);
refreshData();
setInterval(refreshData, REFRESH_MS);

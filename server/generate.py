#!/usr/bin/env python3
"""Genera dashboard/data/data.json: temps, propers esdeveniments i tasques.

El marc no surt a internet: tot el que és extern es consulta aquí i el marc només llegeix el JSON.
Cada secció és independent: si una falla es conserva l'última bona i s'anota a "errors".
Config a server/config.json (fora de git; plantilla a config.example.json).
"""
import hashlib
import json
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(ROOT, "server", "config.json")
OUT_PATH = os.path.join(ROOT, "dashboard", "data", "data.json")
HTTP_TIMEOUT = 20


def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def short_error(exc):
    """Missatge curt i segur per a data.json: sense rutes ni URL (l'URL del calendari pot ser secreta)."""
    name = type(exc).__name__
    if isinstance(exc, urllib.error.HTTPError):
        return f"{name}: HTTP {exc.code}"
    if isinstance(exc, (urllib.error.URLError, TimeoutError)):
        return f"{name}: sense connexió"
    if isinstance(exc, FileNotFoundError):
        return f"{name}: fitxer no trobat"
    if isinstance(exc, OSError):
        return f"{name}: error d'entrada/sortida"
    if isinstance(exc, (KeyError, ValueError, TypeError, IndexError)):
        return f"{name}: dades inesperades"
    return name


def weather_from_json(raw, place):
    daily = raw["daily"]
    return {
        "place": place,
        "temperature": raw["current"]["temperature_2m"],
        "code": raw["current"]["weather_code"],
        "days": [
            {"date": daily["time"][i], "code": daily["weather_code"][i],
             "min": daily["temperature_2m_min"][i], "max": daily["temperature_2m_max"][i]}
            for i in range(len(daily["time"]))
        ],
    }


def fetch_weather(cfg):
    query = urllib.parse.urlencode({
        "latitude": cfg["latitude"], "longitude": cfg["longitude"],
        "current": "temperature_2m,weather_code",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min",
        "timezone": cfg["timezone"], "forecast_days": 3,
    }, safe=",/")
    with urllib.request.urlopen(f"https://api.open-meteo.com/v1/forecast?{query}", timeout=HTTP_TIMEOUT) as resp:
        raw = json.load(resp)
    return weather_from_json(raw, cfg.get("place", ""))


def calendar_configured(cfg):
    return bool(cfg.get("calendar_ical_file") or cfg.get("calendar_ical_url"))


def read_calendar_text(cfg):
    path = cfg.get("calendar_ical_file")
    if path:
        with open(os.path.join(ROOT, path) if not os.path.isabs(path) else path, "rb") as f:
            return f.read()
    with urllib.request.urlopen(cfg["calendar_ical_url"], timeout=HTTP_TIMEOUT) as resp:
        return resp.read()


def events_from_ical(raw_bytes, now, tz, days):
    """Esdeveniments dels propers `days` dies des de la mitjanit local de `now` (aware).

    Tot el dia: start/end "YYYY-MM-DD" amb end inclusiu. Amb hora: ISO amb offset de `tz`.
    """
    import icalendar
    import recurring_ical_events

    start = now.astimezone(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=days)
    cal = icalendar.Calendar.from_ical(raw_bytes)

    def local(dt):
        # Les hores flotants (sense zona) són hores de paret de la zona configurada, no les del servidor
        return dt.replace(tzinfo=tz) if dt.tzinfo is None else dt.astimezone(tz)

    events = []
    for ev in recurring_ical_events.of(cal).between(start, end):
        s = ev.get("DTSTART").dt
        e = ev.get("DTEND").dt if ev.get("DTEND") else None
        duration = ev.get("DURATION").dt if ev.get("DURATION") else None
        all_day = not isinstance(s, datetime)
        if all_day:
            # DTEND és exclusiu; sense DTEND ni DURATION dura un dia
            if e is None and duration is not None:
                e = s + duration
            e_day = max(e - timedelta(days=1), s) if e else s
            s_iso, e_iso = s.isoformat(), e_day.isoformat()
        else:
            s = local(s)
            e = local(e) if e else None
            if e is None or e <= s:
                # recurring_ical_events omple el DTEND absent amb el DTSTART: es tracta com a absent
                e = s + (duration if duration is not None else timedelta(hours=1))
            s_iso, e_iso = s.isoformat(), e.isoformat()
        events.append({"title": str(ev.get("SUMMARY", "")), "start": s_iso, "end": e_iso,
                       "all_day": all_day})
    events.sort(key=lambda x: (x["start"][:10], not x["all_day"], x["start"]))
    return events


def fetch_events(cfg, now=None):
    if not calendar_configured(cfg):
        return []  # calendari sense configurar: no és un error
    tz = ZoneInfo(cfg["timezone"])
    now = now or datetime.now(tz)
    return events_from_ical(read_calendar_text(cfg), now, tz, int(cfg.get("calendar_days_ahead", 14)))


def parse_tasks(text):
    tasks = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        done = line.lower().startswith("[x]")
        text_ = line[3:].strip() if line.startswith(("[ ]", "[x]", "[X]")) else line
        if text_:
            tasks.append({"text": text_, "done": done})
    return tasks


def read_tasks(cfg):
    path = cfg.get("tasks_file", "server/tasks.txt")
    path = path if os.path.isabs(path) else os.path.join(ROOT, path)
    with open(path, encoding="utf-8") as f:
        return parse_tasks(f.read())


def site_version(dashboard_dir=None):
    """Versió de la pàgina: hash curt d'index.html i de tot css/ i js/ (ruta relativa i contingut).

    Canvia sola quan canvia qualsevol fitxer de la pàgina; data/ no hi entra. None si no es pot llegir.
    """
    base = dashboard_dir or os.path.join(ROOT, "dashboard")
    try:
        paths = [os.path.join(base, "index.html")]
        for sub in ("css", "js"):
            for dirpath, _, names in os.walk(os.path.join(base, sub)):
                paths += [os.path.join(dirpath, n) for n in names]
        digest = hashlib.sha256()
        for path in sorted(paths, key=lambda p: os.path.relpath(p, base).replace(os.sep, "/")):
            with open(path, "rb") as f:
                content = f.read()
            digest.update(os.path.relpath(path, base).replace(os.sep, "/").encode("utf-8") + b"\0")
            digest.update(content + b"\0")
        return digest.hexdigest()[:12]
    except OSError:
        return None


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)  # mkstemp crea 0600 i el servidor web podria no poder llegir-lo
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def validate_config(cfg):
    """Retorna un missatge d'error en català (amb la clau afectada) o None si és vàlida."""
    if not isinstance(cfg, dict):
        return "config.json ha de ser un objecte JSON"
    for key, limit in (("latitude", 90), ("longitude", 180)):
        v = cfg.get(key)
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not -limit <= v <= limit:
            return f"Config: «{key}» ha de ser un nombre entre -{limit} i {limit}"
    tzname = cfg.get("timezone")
    try:
        if not isinstance(tzname, str) or not tzname:
            raise ValueError
        ZoneInfo(tzname)
    except (ValueError, OSError, KeyError):  # ZoneInfoNotFoundError és un KeyError
        return "Config: «timezone» ha de ser una zona horària vàlida (p. ex. Europe/Madrid)"
    if "calendar_days_ahead" in cfg:
        d = cfg["calendar_days_ahead"]
        if isinstance(d, bool) or not isinstance(d, int) or d <= 0:
            return "Config: «calendar_days_ahead» ha de ser un enter positiu"
    return None


def build_data(cfg, previous, sections, now):
    """Construeix el JSON. Una secció que falla conserva el valor i el fetched_at anteriors."""
    stamp = now.astimezone(timezone.utc).isoformat(timespec="seconds")
    prev_fetched = previous.get("fetched_at") or {}
    data = {"generated": stamp, "timezone": cfg["timezone"], "site_version": site_version(),
            "fetched_at": {}, "errors": {}}
    for name, fn in sections.items():
        try:
            data[name] = fn(cfg)
            data["fetched_at"][name] = stamp
        except Exception as exc:  # una secció que falla no ha de tombar les altres
            data[name] = previous.get(name)
            if prev_fetched.get(name):
                data["fetched_at"][name] = prev_fetched[name]
            data["errors"][name] = short_error(exc)
            print(f"[{name}] {type(exc).__name__}: {exc}", file=sys.stderr)  # el detall complet, només a stderr
    return data


def main():
    cfg = load_json(CONFIG_PATH)
    if cfg is None:
        print(f"Falta o és invàlid {CONFIG_PATH} (copieu server/config.example.json)", file=sys.stderr)
        return 1
    problem = validate_config(cfg)
    if problem:
        print(problem, file=sys.stderr)
        return 1
    now = datetime.now(timezone.utc)
    previous = load_json(OUT_PATH, {})
    previous = previous if isinstance(previous, dict) else {}
    sections = {"weather": fetch_weather, "events": lambda c: fetch_events(c, now), "tasks": read_tasks}
    data = build_data(cfg, previous, sections, now)
    write_atomic(OUT_PATH, data)
    print(f"OK {OUT_PATH} errors={list(data['errors'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

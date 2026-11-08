#!/usr/bin/env python3
"""Genera dashboard/data/data.json: temps, propers esdeveniments i tasques.

El marc no surt a internet: tot el que és extern es consulta aquí i el marc només llegeix el JSON.
Cada secció és independent: si una falla es conserva l'última bona i s'anota a "errors".
Config a server/config.json (fora de git; plantilla a config.example.json).
"""
import json
import os
import re
import sys
import tempfile
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


def fetch_weather(cfg):
    url = (
        "https://api.open-meteo.com/v1/forecast"
        f"?latitude={cfg['latitude']}&longitude={cfg['longitude']}"
        "&current=temperature_2m,weather_code"
        "&daily=weather_code,temperature_2m_max,temperature_2m_min"
        f"&timezone={cfg['timezone']}&forecast_days=3"
    )
    with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as resp:
        raw = json.load(resp)
    daily = raw["daily"]
    return {
        "place": cfg.get("place", ""),
        "temperature": raw["current"]["temperature_2m"],
        "code": raw["current"]["weather_code"],
        "days": [
            {"date": daily["time"][i], "code": daily["weather_code"][i],
             "min": daily["temperature_2m_min"][i], "max": daily["temperature_2m_max"][i]}
            for i in range(len(daily["time"]))
        ],
    }


def read_calendar_text(cfg):
    path = cfg.get("calendar_ical_file")
    if path:
        with open(os.path.join(ROOT, path) if not os.path.isabs(path) else path, "rb") as f:
            return f.read()
    url = cfg.get("calendar_ical_url")
    if not url:
        raise ValueError("calendari no configurat")
    with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as resp:
        return resp.read()


def fetch_events(cfg):
    import icalendar
    import recurring_ical_events

    tz = ZoneInfo(cfg["timezone"])
    start = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=int(cfg.get("calendar_days_ahead", 14)))
    cal = icalendar.Calendar.from_ical(read_calendar_text(cfg))
    events = []
    for ev in recurring_ical_events.of(cal).between(start, end):
        s, e = ev.get("DTSTART").dt, ev.get("DTEND").dt if ev.get("DTEND") else None
        all_day = not isinstance(s, datetime)
        if all_day:
            s_iso = s.isoformat()
            e_iso = (e - timedelta(days=1)).isoformat() if e else s_iso
        else:
            s_iso = s.astimezone(tz).isoformat()
            e_iso = e.astimezone(tz).isoformat() if e else s_iso
        events.append({"title": str(ev.get("SUMMARY", "")), "start": s_iso, "end": e_iso,
                       "all_day": all_day})
    events.sort(key=lambda x: (x["start"][:10], not x["all_day"], x["start"]))
    return events


def read_tasks(cfg):
    path = cfg.get("tasks_file", "server/tasks.txt")
    path = path if os.path.isabs(path) else os.path.join(ROOT, path)
    tasks = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                done = line.lower().startswith("[x]")
                text = line[3:].strip() if line.startswith(("[ ]", "[x]", "[X]")) else line
                if text:
                    tasks.append({"text": text, "done": done})
    except FileNotFoundError:
        raise ValueError(f"no existeix {path}")
    return tasks


def site_version():
    """Versió de la pàgina, de <meta name="site-version"> a dashboard/index.html."""
    try:
        with open(os.path.join(ROOT, "dashboard", "index.html"), encoding="utf-8") as f:
            match = re.search(r'<meta name="site-version" content="([^"]+)"', f.read())
        return match.group(1) if match else None
    except OSError:
        return None


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def main():
    cfg = load_json(CONFIG_PATH)
    if cfg is None:
        print(f"Falta o és invàlid {CONFIG_PATH} (copieu server/config.example.json)", file=sys.stderr)
        return 1
    previous = load_json(OUT_PATH, {}) or {}
    data = {"generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "site_version": site_version(), "errors": {}}
    sections = {"weather": fetch_weather, "events": fetch_events, "tasks": read_tasks}
    for name, fn in sections.items():
        try:
            data[name] = fn(cfg)
        except Exception as exc:  # una secció que falla no ha de tombar les altres
            data[name] = previous.get(name)
            data["errors"][name] = f"{type(exc).__name__}: {exc}"
            print(f"[{name}] {data['errors'][name]}", file=sys.stderr)
    write_atomic(OUT_PATH, data)
    print(f"OK {OUT_PATH} errors={list(data['errors'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

import json
import os
import stat
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import pytest

import generate

TZ = ZoneInfo("Europe/Madrid")
FIX = os.path.join(os.path.dirname(__file__), "fixtures")
NOW = datetime(2026, 3, 10, 8, 0, tzinfo=TZ)


def events(name, now=NOW, days=14, tz=TZ):
    with open(os.path.join(FIX, name), "rb") as f:
        return generate.events_from_ical(f.read(), now, tz, days)


def by_title(evs):
    return {e["title"]: e for e in evs}


# --- tasques

def test_parse_tasks():
    text = "# comentari\n\n[ ] Pa\n[x] Llum\n[X] Gas\nSense marca\n   \n[ ]\n  [ ]  Amb espais  \n"
    assert generate.parse_tasks(text) == [
        {"text": "Pa", "done": False}, {"text": "Llum", "done": True}, {"text": "Gas", "done": True},
        {"text": "Sense marca", "done": False}, {"text": "Amb espais", "done": False}]


# --- esdeveniments

def test_timed():
    assert events("timed.ics") == [{"title": "Dentista", "start": "2026-03-10T18:30:00+01:00",
                                    "end": "2026-03-10T19:45:00+01:00", "all_day": False}]


def test_all_day_single_and_multi_inclusive_end():
    ev = by_title(events("allday.ics"))
    assert (ev["Festa"]["start"], ev["Festa"]["end"], ev["Festa"]["all_day"]) == ("2026-03-11", "2026-03-11", True)
    assert (ev["Viatge"]["start"], ev["Viatge"]["end"]) == ("2026-03-12", "2026-03-14")


def test_all_day_without_end_is_one_day_and_duration_is_used():
    ev = by_title(events("allday.ics"))
    assert (ev["Sense final"]["start"], ev["Sense final"]["end"]) == ("2026-03-16", "2026-03-16")
    assert (ev["Amb durada"]["start"], ev["Amb durada"]["end"]) == ("2026-03-17", "2026-03-18")


def test_duration_and_default_one_hour():
    ev = by_title(events("duration.ics"))
    assert ev["Reunio"]["end"] == "2026-03-10T11:30:00+01:00"
    assert ev["Sense final"]["end"] == "2026-03-10T13:00:00+01:00"


def test_recurring_expanded_inside_window():
    starts = [e["start"][:10] for e in events("recurring.ics", days=14)]
    # now = dimarts 10/03: els dilluns dins de 14 dies són 16/03 i 23/03
    assert starts == ["2026-03-16", "2026-03-23"]


def test_floating_uses_configured_timezone(monkeypatch):
    # Si el servidor és en una altra zona, l'hora flotant ha de seguir sent hora de Madrid
    monkeypatch.setenv("TZ", "America/New_York")
    import time
    time.tzset()
    try:
        ev = events("floating.ics")[0]
    finally:
        monkeypatch.undo()
        time.tzset()
    assert ev["start"] == "2026-03-10T20:00:00+01:00"
    assert ev["end"] == "2026-03-10T21:00:00+01:00"


def test_floating_in_another_configured_timezone():
    ev = events("floating.ics", now=datetime(2026, 3, 10, 8, tzinfo=ZoneInfo("Atlantic/Canary")),
                tz=ZoneInfo("Atlantic/Canary"))[0]
    assert ev["start"] == "2026-03-10T20:00:00+00:00"


def test_dst_change_offsets():
    now = datetime(2026, 3, 28, 8, 0, tzinfo=TZ)
    ev = events("dst.ics", now=now, days=3)
    assert ev[0]["start"] == "2026-03-28T23:00:00+01:00"
    assert ev[0]["end"] == "2026-03-29T04:00:00+02:00"
    assert ev[1]["start"] == "2026-03-29T12:00:00+02:00"


def test_sort_order():
    assert [e["title"] for e in events("sort.ics")] == ["Abans", "A tot el dia", "Aviat", "B matí"]


# --- meteo

def test_weather_from_json():
    with open(os.path.join(FIX, "openmeteo.json")) as f:
        w = generate.weather_from_json(json.load(f), "Casa")
    assert w == {"place": "Casa", "temperature": 12.4, "code": 3, "days": [
        {"date": "2026-03-10", "code": 3, "min": 7.2, "max": 15.1},
        {"date": "2026-03-11", "code": 61, "min": 6.5, "max": 13.0}]}


# --- write_atomic

def test_write_atomic_mode_and_content(tmp_path):
    path = tmp_path / "out" / "data.json"
    generate.write_atomic(str(path), {"a": "é"})
    assert stat.S_IMODE(path.stat().st_mode) == 0o644
    assert json.loads(path.read_text(encoding="utf-8")) == {"a": "é"}
    assert [p.name for p in path.parent.iterdir()] == ["data.json"]


def test_write_atomic_cleans_up_on_failure(tmp_path):
    path = tmp_path / "data.json"
    path.write_text('{"old": 1}')
    with pytest.raises(TypeError):
        generate.write_atomic(str(path), {"x": object()})
    assert [p.name for p in tmp_path.iterdir()] == ["data.json"]
    assert json.loads(path.read_text()) == {"old": 1}


# --- config

GOOD = {"latitude": 41.49, "longitude": 2.36, "timezone": "Europe/Madrid", "calendar_days_ahead": 14}


def test_validate_config_ok():
    assert generate.validate_config(GOOD) is None
    assert generate.validate_config({k: GOOD[k] for k in ("latitude", "longitude", "timezone")}) is None


@pytest.mark.parametrize("key,value", [
    ("latitude", 91), ("latitude", "41"), ("latitude", None), ("longitude", -181), ("longitude", True),
    ("timezone", "Mars/Olympus"), ("timezone", ""), ("timezone", 5),
    ("calendar_days_ahead", 0), ("calendar_days_ahead", -3), ("calendar_days_ahead", "14"), ("calendar_days_ahead", 1.5)])
def test_validate_config_bad_value_names_key(key, value):
    msg = generate.validate_config({**GOOD, key: value})
    assert msg and f"«{key}»" in msg


@pytest.mark.parametrize("key", ["latitude", "longitude", "timezone"])
def test_validate_config_missing_key(key):
    cfg = {k: v for k, v in GOOD.items() if k != key}
    assert f"«{key}»" in generate.validate_config(cfg)


def test_main_rejects_bad_config(tmp_path, monkeypatch, capsys):
    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({**GOOD, "latitude": 999}))
    monkeypatch.setattr(generate, "CONFIG_PATH", str(cfg))
    monkeypatch.setattr(generate, "OUT_PATH", str(tmp_path / "data.json"))
    assert generate.main() == 1
    assert "latitude" in capsys.readouterr().err
    assert not (tmp_path / "data.json").exists()


def test_unconfigured_calendar_is_empty_not_error():
    cfg = {**GOOD, "calendar_ical_url": "", "calendar_ical_file": ""}
    assert generate.fetch_events(cfg) == []
    data = generate.build_data(cfg, {}, {"events": generate.fetch_events}, NOW)
    assert data["events"] == [] and data["errors"] == {}


# --- site_version

def make_site(root):
    (root / "css").mkdir(parents=True)
    (root / "js").mkdir()
    (root / "data").mkdir()
    (root / "index.html").write_text("<html></html>")
    (root / "css" / "style.css").write_text("body{}")
    (root / "js" / "app.js").write_text("var a;")
    return str(root)


def test_site_version_stable_and_short(tmp_path):
    site = make_site(tmp_path)
    v = generate.site_version(site)
    assert v == generate.site_version(site)
    assert len(v) == 12 and int(v, 16) >= 0


@pytest.mark.parametrize("name", ["index.html", "css/style.css", "js/app.js"])
def test_site_version_changes_with_any_file(tmp_path, name):
    site = make_site(tmp_path)
    before = generate.site_version(site)
    (tmp_path / name).write_text("canvi")
    assert generate.site_version(site) != before


def test_site_version_changes_with_new_file_and_path(tmp_path):
    site = make_site(tmp_path)
    before = generate.site_version(site)
    (tmp_path / "js" / "b.js").write_text("x")
    added = generate.site_version(site)
    assert added != before
    (tmp_path / "js" / "b.js").rename(tmp_path / "js" / "c.js")
    assert generate.site_version(site) not in (before, added)


def test_site_version_ignores_data(tmp_path):
    site = make_site(tmp_path)
    before = generate.site_version(site)
    (tmp_path / "data" / "data.json").write_text('{"a": 1}')
    assert generate.site_version(site) == before


def test_site_version_none_without_index(tmp_path):
    site = make_site(tmp_path)
    (tmp_path / "index.html").unlink()
    assert generate.site_version(site) is None


def test_site_version_default_reads_dashboard_under_root(tmp_path, monkeypatch):
    (tmp_path / "dashboard").mkdir()
    site = make_site(tmp_path / "dashboard")
    monkeypatch.setattr(generate, "ROOT", str(tmp_path))
    assert generate.site_version() == generate.site_version(site)


# --- build_data i fallback

def boom(cfg):
    raise generate.urllib.error.URLError("https://secret.example/cal.ics?token=abc")


def test_build_data_success_shape():
    data = generate.build_data(GOOD, {}, {"tasks": lambda c: [1]}, NOW)
    assert data["timezone"] == "Europe/Madrid"
    assert data["fetched_at"] == {"tasks": "2026-03-10T07:00:00+00:00"}
    assert data["generated"] == "2026-03-10T07:00:00+00:00"
    assert data["errors"] == {} and data["tasks"] == [1]


def test_build_data_fallback_keeps_previous_value_and_fetched_at(capsys):
    previous = {"weather": {"temperature": 1}, "events": [{"title": "x"}],
                "fetched_at": {"weather": "2026-03-09T00:00:00+00:00", "events": "2026-03-09T00:00:00+00:00"}}
    data = generate.build_data(GOOD, previous, {"weather": boom, "events": lambda c: []}, NOW)
    assert data["weather"] == {"temperature": 1}
    assert data["fetched_at"]["weather"] == "2026-03-09T00:00:00+00:00"
    assert data["fetched_at"]["events"] == "2026-03-10T07:00:00+00:00"
    assert list(data["errors"]) == ["weather"]
    assert "secret" not in json.dumps(data) and "token" not in json.dumps(data)
    assert "secret.example" in capsys.readouterr().err


def test_build_data_failure_without_previous_has_no_fetched_at():
    data = generate.build_data(GOOD, {}, {"weather": boom}, NOW)
    assert data["weather"] is None and "weather" not in data["fetched_at"]
    assert "weather" in data["errors"]


def test_short_error_has_no_paths():
    msg = generate.short_error(FileNotFoundError(2, "No such file", "/home/x/secret/tasks.txt"))
    assert "/home" not in msg and msg.startswith("FileNotFoundError")


def test_read_tasks_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        generate.read_tasks({"tasks_file": str(tmp_path / "no.txt")})

"""JSON-file store. Single-match scope: one row of tokens + an events ring buffer."""
from __future__ import annotations

import asyncio
import json
import os
import time
from pathlib import Path
from typing import Any

_DATA_PATH = Path(__file__).resolve().parent / "data.json"
_LOCK = asyncio.Lock()
_MAX_EVENTS = 100

_DEFAULT: dict[str, Any] = {
    "device_token": None,
    "push_to_start_token": None,
    "activity_id": None,
    "activity_token": None,
    "match_id": None,
    "updated_at": None,
    "events": [],
}


def _read() -> dict[str, Any]:
    if not _DATA_PATH.exists():
        return json.loads(json.dumps(_DEFAULT))  # deep copy
    try:
        return {**_DEFAULT, **json.loads(_DATA_PATH.read_text())}
    except json.JSONDecodeError:
        return json.loads(json.dumps(_DEFAULT))


def _write(data: dict[str, Any]) -> None:
    tmp = _DATA_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    os.replace(tmp, _DATA_PATH)


async def get_state() -> dict[str, Any]:
    async with _LOCK:
        return _read()


async def patch(**fields: Any) -> dict[str, Any]:
    async with _LOCK:
        data = _read()
        data.update(fields)
        data["updated_at"] = int(time.time())
        _write(data)
        return data


async def clear_activity(activity_id: str | None = None) -> dict[str, Any]:
    async with _LOCK:
        data = _read()
        if activity_id is None or data.get("activity_id") == activity_id:
            data["activity_id"] = None
            data["activity_token"] = None
            data["updated_at"] = int(time.time())
            _write(data)
        return data


async def log_event(kind: str, detail: dict[str, Any]) -> None:
    async with _LOCK:
        data = _read()
        evt = {"ts": int(time.time()), "kind": kind, "detail": detail}
        events = data.get("events", [])
        events.insert(0, evt)
        data["events"] = events[:_MAX_EVENTS]
        _write(data)

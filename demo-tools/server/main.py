"""FastAPI MVP for the Live Activity demo backend.

Run:
    cd demo-tools/server && ./run.sh

Endpoints (see /docs for OpenAPI):
    POST /api/tokens/device           {token}
    POST /api/tokens/push-to-start    {token}
    POST /api/tokens/activity         {activity_id, token, match_id?}
    POST /api/tokens/activity/clear   {activity_id?}
    POST /api/push/start              {home?, away?, minute?}
    POST /api/push/update             {home, away, minute, alert?}
    POST /api/push/end                {home?, away?}
    POST /api/push/silent
    GET  /api/state
    GET  /                            dashboard
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

import apns
import store

app = FastAPI(title="LiveActivityDemo Backend")

STATIC_DIR = Path(__file__).resolve().parent / "static"
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


# ---------------- Schemas ----------------

class DeviceTokenIn(BaseModel):
    token: str


class PushToStartTokenIn(BaseModel):
    token: str


class ActivityTokenIn(BaseModel):
    activity_id: str
    token: str
    match_id: str | None = None


class ClearActivityIn(BaseModel):
    activity_id: str | None = None


class StartIn(BaseModel):
    home: int = 0
    away: int = 0
    minute: str = "0'"


class UpdateIn(BaseModel):
    home: int
    away: int
    minute: str
    alert: bool = False


class EndIn(BaseModel):
    home: int = 0
    away: int = 0


# ---------------- Token upload ----------------

@app.post("/api/tokens/device")
async def upload_device_token(body: DeviceTokenIn) -> dict[str, Any]:
    await store.patch(device_token=body.token)
    await store.log_event("token.device", {"token": _short(body.token)})
    return {"ok": True}


@app.post("/api/tokens/push-to-start")
async def upload_p2s_token(body: PushToStartTokenIn) -> dict[str, Any]:
    await store.patch(push_to_start_token=body.token)
    await store.log_event("token.push_to_start", {"token": _short(body.token)})
    return {"ok": True}


@app.post("/api/tokens/activity")
async def upload_activity_token(body: ActivityTokenIn) -> dict[str, Any]:
    await store.patch(
        activity_id=body.activity_id,
        activity_token=body.token,
        match_id=body.match_id,
    )
    await store.log_event(
        "token.activity",
        {"activity_id": body.activity_id, "token": _short(body.token), "match_id": body.match_id},
    )
    return {"ok": True}


@app.post("/api/tokens/activity/clear")
async def clear_activity_token(body: ClearActivityIn) -> dict[str, Any]:
    await store.clear_activity(body.activity_id)
    await store.log_event("token.activity.clear", {"activity_id": body.activity_id})
    return {"ok": True}


# ---------------- Push debug ----------------

@app.post("/api/push/start")
async def push_start(body: StartIn) -> dict[str, Any]:
    """方案 B：silent push 唤醒 app → app 本地创建 Activity。
    比 push-to-start 稳定（iOS 18 push-to-start 不分配 activity push token）。
    前置：app 至少冷启动一次完成 device token 注册。"""
    state = await store.get_state()
    device_token = state.get("device_token")
    if not device_token:
        raise HTTPException(400, "no device_token — launch the app at least once first")
    payload = apns.build_create_via_silent(body.home, body.away, body.minute)
    result = await apns.send_silent_payload(device_token, payload)
    await store.log_event("push.create_via_silent", _result_for_log(result))
    return result


@app.post("/api/push/start-via-p2s")
async def push_start_via_p2s(body: StartIn) -> dict[str, Any]:
    """旧路径（调试用）：APNs push-to-start 直接创建 Activity。
    iOS 18.x 上 activity push token 拿不到，仅作对照保留。"""
    state = await store.get_state()
    p2s_token = state.get("push_to_start_token")
    if not p2s_token:
        raise HTTPException(400, "no push_to_start_token")
    payload = apns.build_start(body.home, body.away, body.minute)
    result = await apns.send_liveactivity(p2s_token, payload)
    await store.log_event("push.start_via_p2s", _result_for_log(result))
    if result["status"] == 200:
        device_token = state.get("device_token")
        if device_token:
            silent_result = await apns.send_silent(device_token)
            await store.log_event("push.silent_after_start", _result_for_log(silent_result))
    return result


@app.post("/api/push/update")
async def push_update(body: UpdateIn) -> dict[str, Any]:
    state = await store.get_state()
    token = state.get("activity_token")
    if not token:
        raise HTTPException(400, "no activity_token")
    payload = apns.build_update(body.home, body.away, body.minute, body.alert)
    result = await apns.send_liveactivity(token, payload)
    await store.log_event("push.update", _result_for_log(result))
    # 410 ExpiredToken → 自动清理本地映射
    if result["status"] == 410:
        await store.clear_activity()
    return result


@app.post("/api/push/end")
async def push_end(body: EndIn) -> dict[str, Any]:
    state = await store.get_state()
    token = state.get("activity_token")
    if not token:
        raise HTTPException(400, "no activity_token")
    payload = apns.build_end(body.home, body.away)
    result = await apns.send_liveactivity(token, payload)
    await store.log_event("push.end", _result_for_log(result))
    if result["status"] in (200, 410):
        await store.clear_activity()
    return result


@app.post("/api/push/silent")
async def push_silent() -> dict[str, Any]:
    state = await store.get_state()
    token = state.get("device_token")
    if not token:
        raise HTTPException(400, "no device_token")
    result = await apns.send_silent(token)
    await store.log_event("push.silent", _result_for_log(result))
    return result


# ---------------- State / UI ----------------

@app.get("/api/state")
async def get_state() -> dict[str, Any]:
    state = await store.get_state()
    return {"config": apns.config_summary(), "state": state}


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


# ---------------- Helpers ----------------

def _short(s: str | None) -> str | None:
    if not s:
        return s
    return s if len(s) <= 16 else f"{s[:8]}…{s[-8:]}"


def _result_for_log(r: dict[str, Any]) -> dict[str, Any]:
    return {"status": r["status"], "apns_id": r.get("apns_id"), "body": r.get("body")}

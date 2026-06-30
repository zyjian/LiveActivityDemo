"""APNs client: ES256 JWT + HTTP/2 POST. Mirrors demo-tools/push.sh payloads."""
from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any

import httpx
import jwt

TEAM_ID = os.environ.get("TEAM_ID", "TG5E95RU8K")
KEY_ID = os.environ.get("KEY_ID", "9TLPL9K79A")
AUTH_KEY = os.environ.get(
    "AUTH_KEY",
    str(Path.home() / ".apns" / f"AuthKey_{KEY_ID}.p8"),
)
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.zhu.LiveActivityDemo")
APNS_HOST = os.environ.get("APNS_HOST", "api.development.push.apple.com")

_LA_TOPIC = f"{BUNDLE_ID}.push-type.liveactivity"

_jwt_cache: dict[str, Any] = {"token": None, "iat": 0}


def _jwt_token() -> str:
    # Apple wants JWT refreshed roughly every 20-60 min; refresh at ~50 min.
    now = int(time.time())
    if _jwt_cache["token"] and now - _jwt_cache["iat"] < 50 * 60:
        return _jwt_cache["token"]
    key = Path(AUTH_KEY).read_text()
    tok = jwt.encode(
        {"iss": TEAM_ID, "iat": now},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )
    _jwt_cache["token"] = tok
    _jwt_cache["iat"] = now
    return tok


# ---------------- Payload builders ----------------

_ATTRIBUTES = {
    "appName": "Gate",
    "matchStageTitle": "欧冠 半决赛 次回合",
    "homeTeamName": "拜仁慕尼黑",
    "awayTeamName": "巴黎圣日耳曼",
    "homeTeamLogoURL": "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1b/FC_Bayern_M%C3%BCnchen_logo_%282017%29.svg/120px-FC_Bayern_M%C3%BCnchen_logo_%282017%29.svg.png",
    "awayTeamLogoURL": "https://upload.wikimedia.org/wikipedia/en/thumb/a/a7/Paris_Saint-Germain_F.C..svg/120px-Paris_Saint-Germain_F.C..svg.png",
}


def _content_state(home: int, away: int, minute: str, aggregate: str = "首回合 4-5") -> dict[str, Any]:
    return {
        "homeScore": home,
        "awayScore": away,
        "minuteText": minute,
        "aggregateLine": aggregate,
    }


def build_start(home: int, away: int, minute: str) -> dict[str, Any]:
    now = int(time.time())
    return {
        "aps": {
            "timestamp": now,
            "event": "start",
            "attributes-type": "MyWidgetAttributes",
            "attributes": _ATTRIBUTES,
            "content-state": _content_state(home, away, minute),
            "alert": {"title": "比赛开始", "body": f"{home}-{away} · {minute}"},
            "stale-date": now + 3600,
            "dismissal-date": now + 7200,
            # iOS 18 实验性：声明 push-to-start 创建的 activity 用 token 模式接收后续更新。
            # 官方文档未明确列出该字段；社区开发者反馈 iOS 18+ 在此 key 存在时才会分配 activity push token。
            "input-push-token": 1,
        }
    }


def build_update(home: int, away: int, minute: str, alert: bool) -> dict[str, Any]:
    aps: dict[str, Any] = {
        "timestamp": int(time.time()),
        "event": "update",
        "content-state": _content_state(home, away, minute),
    }
    if alert:
        aps["alert"] = {"title": "比分更新", "body": f"{home}-{away} · {minute}"}
    return {"aps": aps}


def build_end(home: int, away: int) -> dict[str, Any]:
    now = int(time.time())
    return {
        "aps": {
            "timestamp": now,
            "event": "end",
            "dismissal-date": now + 60,
            "content-state": _content_state(home, away, "终场", "结束"),
        }
    }


def build_silent() -> dict[str, Any]:
    return {"aps": {"content-available": 1}}


def build_create_via_silent(home: int, away: int, minute: str) -> dict[str, Any]:
    """方案 B：silent push payload 携带活动创建参数。
    iOS 端 didReceiveRemoteNotification 解析 la_create → 本地 Activity.request。
    绕开 iOS 18 push-to-start 不分配 activity push token 的问题。"""
    return {
        "aps": {"content-available": 1},
        "la_create": {
            "attributes": _ATTRIBUTES,
            "content_state": _content_state(home, away, minute),
        },
    }


async def send_silent_payload(token: str, payload: dict[str, Any]) -> dict[str, Any]:
    """自定义 silent push（携带任意业务 payload）。apns-priority 必须 5，否则被拒。"""
    return await _post(token, payload, push_type="background", topic=BUNDLE_ID, priority="5")


# ---------------- HTTP send ----------------

async def _post(token: str, payload: dict[str, Any], *, push_type: str, topic: str, priority: str) -> dict[str, Any]:
    headers = {
        "authorization": f"bearer {_jwt_token()}",
        "apns-topic": topic,
        "apns-push-type": push_type,
        "apns-priority": priority,
    }
    url = f"https://{APNS_HOST}/3/device/{token}"
    async with httpx.AsyncClient(http2=True, timeout=10.0) as client:
        resp = await client.post(url, headers=headers, json=payload)
    return {
        "status": resp.status_code,
        "apns_id": resp.headers.get("apns-id"),
        "body": resp.text,
        "url": url,
        "payload": payload,
    }


async def send_liveactivity(token: str, payload: dict[str, Any]) -> dict[str, Any]:
    return await _post(token, payload, push_type="liveactivity", topic=_LA_TOPIC, priority="10")


async def send_silent(token: str) -> dict[str, Any]:
    return await _post(token, build_silent(), push_type="background", topic=BUNDLE_ID, priority="5")


def config_summary() -> dict[str, Any]:
    return {
        "team_id": TEAM_ID,
        "key_id": KEY_ID,
        "auth_key": AUTH_KEY,
        "auth_key_exists": Path(AUTH_KEY).exists(),
        "bundle_id": BUNDLE_ID,
        "apns_host": APNS_HOST,
    }

#!/usr/bin/env bash
# Push a Live Activity payload to Apple's development APNs.
#
# Usage:
#   1) Fill in the four CONFIG values below (or export them as env vars).
#   2) Run:
#        ./push.sh <activity-push-token> update        [home] [away] [minute]
#        ./push.sh <activity-push-token> tick          [home] [away] [minute]   # 静默更新：无 alert + priority 5
#        ./push.sh <device-token>        silent-create [home] [away] [minute]   # 方案 B 主路径
#        ./push.sh <push-to-start-token> start         [home] [away] [minute]   # 旧 push-to-start
#        ./push.sh <activity-push-token> end
#        ./push.sh <device-token>        silent
#
# Examples:
#   ./push.sh 8f3c... silent-create 0 0 "0'"      # ★ 推荐：唤醒 app 本地创建 Activity
#   ./push.sh 8f3c... update 1 2 "55'"            # 进球/关键事件：有横幅有声
#   ./push.sh 8f3c... tick   1 2 "56'"            # 仅时钟刷新：静默，无声无横幅
#   ./push.sh 8f3c... start  0 0 "0'"             # 旧路径，iOS 18 拿不到 token
#   ./push.sh 8f3c... end
#   ./push.sh 8f3c... silent
#
# Notes:
# - "update" / "tick" / "end" need the per-Activity push token printed by Activity.pushTokenUpdates.
# - "tick" 与 "update" 区别：tick 不带 alert + apns-priority=5，仅刷新 content-state，
#   不会触发横幅 / 声音 / 锁屏唤醒，适合每分钟时钟滚动；priority 5 还会被 APNs 合并节流。
# - "start" needs the push-to-start token printed by observePushToStartTokens (iOS 17.2+).
# - "silent" needs the standard APNs device token printed by didRegisterForRemoteNotifications-
#   WithDeviceToken. It wakes the app in background (~30s) so it can read & upload the new
#   activity push token created by a preceding push-to-start. apns-topic uses the plain bundle id.
# - apns-topic for Live Activity is always "<bundleId>.push-type.liveactivity".
                                                                  

set -euo pipefail

# -------- CONFIG (override via env if you prefer) --------
TEAM_ID="${TEAM_ID:-TG5E95RU8K}"                                          # Apple Developer Team ID
KEY_ID="${KEY_ID:-9TLPL9K79A}"                                            # APNs Auth Key ID
AUTH_KEY="${AUTH_KEY:-$HOME/.apns/AuthKey_${KEY_ID}.p8}"                  # path to your .p8
BUNDLE_ID="${BUNDLE_ID:-com.zhu.LiveActivityDemo}"                        # main app bundle id
APNS_HOST="${APNS_HOST:-api.development.push.apple.com}"                  # use api.push.apple.com for prod
# ---------------------------------------------------------

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <token> <update|start|end> [home] [away] [minute]" >&2
  exit 1
fi

TOKEN="$1"
EVENT="$2"
HOME_SCORE="${3:-0}"
AWAY_SCORE="${4:-0}"
MINUTE="${5:-0\'}"

if [[ ! -f "$AUTH_KEY" ]]; then
  echo "AUTH_KEY not found: $AUTH_KEY" >&2
  exit 1
fi

# ---- Build a short-lived ES256 JWT signed by the .p8 ----
NOW="$(date +%s)"
HEADER_JSON=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KEY_ID")
CLAIMS_JSON=$(printf '{"iss":"%s","iat":%s}' "$TEAM_ID" "$NOW")

b64url() { openssl base64 -e -A | tr -d '=' | tr '+/' '-_'; }
HEADER_B64="$(printf '%s' "$HEADER_JSON" | b64url)"
CLAIMS_B64="$(printf '%s' "$CLAIMS_JSON" | b64url)"
SIGNING_INPUT="${HEADER_B64}.${CLAIMS_B64}"
SIGNATURE_B64="$(printf '%s' "$SIGNING_INPUT" \
  | openssl dgst -sha256 -sign "$AUTH_KEY" \
  | openssl asn1parse -inform DER \
  | awk -F: '/INTEGER/ {print $4}' \
  | xxd -r -p \
  | b64url)"
JWT="${SIGNING_INPUT}.${SIGNATURE_B64}"

# ---- Build payload by event ----
TS="$NOW"
case "$EVENT" in
  update)
    PAYLOAD=$(cat <<EOF
{
  "aps": {
    "timestamp": ${TS},
    "event": "update",
    "content-state": {
      "homeScore": ${HOME_SCORE},
      "awayScore": ${AWAY_SCORE},
      "minuteText": "${MINUTE}",
      "aggregateLine": "首回合 4-5"
    },
    "alert": {
      "title": "比分更新",
      "body": "${HOME_SCORE}-${AWAY_SCORE} · ${MINUTE}"
    }
  }
}
EOF
)
    ;;
  tick)
    # 静默更新：仅刷新 content-state，无 alert。底部路由会把 priority 降到 5。
    PAYLOAD=$(cat <<EOF
{
  "aps": {
    "timestamp": ${TS},
    "event": "update",
    "content-state": {
      "homeScore": ${HOME_SCORE},
      "awayScore": ${AWAY_SCORE},
      "minuteText": "${MINUTE}",
      "aggregateLine": "首回合 4-5"
    }
  }
}
EOF
)
    ;;
  start)
    PAYLOAD=$(cat <<EOF
{
  "aps": {
    "timestamp": ${TS},
    "event": "start",
    "attributes-type": "MyWidgetAttributes",
    "attributes": {
      "appName": "Gate",
      "matchStageTitle": "欧冠 半决赛 次回合",
      "homeTeamName": "拜仁慕尼黑",
      "awayTeamName": "巴黎圣日耳曼",
      "homeTeamLogoURL": "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1b/FC_Bayern_M%C3%BCnchen_logo_%282017%29.svg/120px-FC_Bayern_M%C3%BCnchen_logo_%282017%29.svg.png",
      "awayTeamLogoURL": "https://upload.wikimedia.org/wikipedia/en/thumb/a/a7/Paris_Saint-Germain_F.C..svg/120px-Paris_Saint-Germain_F.C..svg.png"
    },
    "content-state": {
      "homeScore": ${HOME_SCORE},
      "awayScore": ${AWAY_SCORE},
      "minuteText": "${MINUTE}",
      "aggregateLine": "首回合 4-5"
    },
    "alert": {
      "title": "比赛开始",
      "body": "${HOME_SCORE}-${AWAY_SCORE} · ${MINUTE}"
    },
    "stale-date": $((TS + 3600)),
    "dismissal-date": $((TS + 7200)),
    "input-push-token": 1
  }
}
EOF
)
    ;;
  end)
    PAYLOAD=$(cat <<EOF
{
  "aps": {
    "timestamp": ${TS},
    "event": "end",
    "dismissal-date": $((TS + 60)),
    "content-state": {
      "homeScore": ${HOME_SCORE},
      "awayScore": ${AWAY_SCORE},
      "minuteText": "终场",
      "aggregateLine": "结束"
    }
  }
}
EOF
)
    ;;
  silent)
    PAYLOAD='{"aps":{"content-available":1}}'
    ;;
  silent-create)
    # 方案 B：silent push 携带 la_create payload，app 后台收到后本地 Activity.request 创建。
    # TOKEN 用 device token（不是 push-to-start token）。
    PAYLOAD=$(cat <<EOF
{
  "aps": {"content-available": 1},
  "la_create": {
    "attributes": {
      "appName": "Gate",
      "matchStageTitle": "欧冠 半决赛 次回合",
      "homeTeamName": "拜仁慕尼黑",
      "awayTeamName": "巴黎圣日耳曼",
      "homeTeamLogoURL": "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1b/FC_Bayern_M%C3%BCnchen_logo_%282017%29.svg/120px-FC_Bayern_M%C3%BCnchen_logo_%282017%29.svg.png",
      "awayTeamLogoURL": "https://upload.wikimedia.org/wikipedia/en/thumb/a/a7/Paris_Saint-Germain_F.C..svg/120px-Paris_Saint-Germain_F.C..svg.png"
    },
    "content_state": {
      "homeScore": ${HOME_SCORE},
      "awayScore": ${AWAY_SCORE},
      "minuteText": "${MINUTE}",
      "aggregateLine": "首回合 4-5"
    }
  }
}
EOF
)
    ;;
  *)
    echo "unknown event: $EVENT (expected: update | tick | start | end | silent | silent-create)" >&2
    exit 1
    ;;
esac

# silent push goes to the app proper (background wake-up); LA pushes use a sub-topic.
if [[ "$EVENT" == "silent" || "$EVENT" == "silent-create" ]]; then
  APNS_TOPIC="${BUNDLE_ID}"
  APNS_PUSH_TYPE="background"
  APNS_PRIORITY="5"
else
  APNS_TOPIC="${BUNDLE_ID}.push-type.liveactivity"
  APNS_PUSH_TYPE="liveactivity"
  if [[ "$EVENT" == "tick" ]]; then
    APNS_PRIORITY="5"
  else
    APNS_PRIORITY="10"
  fi
fi

echo ">> POST https://${APNS_HOST}/3/device/${TOKEN}"
echo ">> apns-topic: ${APNS_TOPIC}"
echo ">> apns-push-type: ${APNS_PUSH_TYPE}"
echo ">> payload:"
echo "$PAYLOAD"
echo

curl -v --http2 \
  --header "authorization: bearer ${JWT}" \
  --header "apns-topic: ${APNS_TOPIC}" \
  --header "apns-push-type: ${APNS_PUSH_TYPE}" \
  --header "apns-priority: ${APNS_PRIORITY}" \
  --data "$PAYLOAD" \
  "https://${APNS_HOST}/3/device/${TOKEN}"
echo

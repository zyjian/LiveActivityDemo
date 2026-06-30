#!/usr/bin/env bash
# Start the LiveActivityDemo backend MVP.
#   ./run.sh             # http://127.0.0.1:8000
#   PORT=9000 ./run.sh   # custom port
#   HOST=0.0.0.0 ./run.sh  # bind LAN (default; iPhone on same WiFi can hit it)
set -euo pipefail
cd "$(dirname "$0")"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"

# 屏蔽 macOS 系统代理（Charles/Proxyman 没运行时 pip / httpx 会被它带跑）
export HTTPS_PROXY="" HTTP_PROXY="" https_proxy="" http_proxy="" no_proxy="*"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q --proxy="" -r requirements.txt

echo ">> dashboard: http://${HOST}:${PORT}/"
echo ">> openapi:   http://${HOST}:${PORT}/docs"
exec uvicorn main:app --host "$HOST" --port "$PORT" --reload

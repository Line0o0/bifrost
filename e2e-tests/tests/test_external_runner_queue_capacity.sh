#!/usr/bin/env bash
set -euo pipefail

unset BIFROST_DETACHED_DAEMON_CHILD
unset BIFROST_EXTERNAL_CLI_QUEUE_TIMEOUT_SECS
: "${BIFROST_SYNC_DISABLE_AUTO_LOGIN_PROMPT:=1}"
: "${BIFROST_DISABLE_TRAY:=1}"
: "${BIFROST_IM_GATEWAY_EXECUTION_MODE:=legacy}"
: "${BIFROST_EXTERNAL_CLI_EXECUTION_MODE:=worker}"
: "${BIFROST_EXTERNAL_CLI_MAX_CONCURRENCY:=4}"
: "${BIFROST_EXTERNAL_CLI_QUEUE_CAPACITY:=16}"
export BIFROST_SYNC_DISABLE_AUTO_LOGIN_PROMPT BIFROST_DISABLE_TRAY
export BIFROST_IM_GATEWAY_EXECUTION_MODE BIFROST_EXTERNAL_CLI_EXECUTION_MODE
export BIFROST_EXTERNAL_CLI_MAX_CONCURRENCY BIFROST_EXTERNAL_CLI_QUEUE_CAPACITY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_DIR"

TEST_DIR="$(mktemp -d "$REPO_DIR/.bifrost-e2e-external-queue.XXXXXX")"
export BIFROST_DATA_DIR="$TEST_DIR"
source "$REPO_DIR/e2e-tests/test_utils/process.sh"
mark_e2e_data_root "$TEST_DIR"

BIFROST_BIN="${BIFROST_BIN:-$REPO_DIR/target/debug/bifrost}"
BIFROST_LOG="$TEST_DIR/bifrost.log"
MOCK_LOG="$TEST_DIR/mock-started.log"
BIFROST_PORT="${BIFROST_PORT:-$(python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)}"
RUN_PIDS=()

cleanup() {
  for pid in "${RUN_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  if [[ -x "${BIFROST_BIN:-}" ]]; then
    BIFROST_DATA_DIR="$TEST_DIR" "$BIFROST_BIN" stop >/dev/null 2>&1 || true
  fi
  kill_bifrost_in_data_root "$TEST_DIR" >/dev/null 2>&1 || true
  if [[ "${KEEP_TEST_DIR:-false}" == "true" ]]; then
    echo "[external-runner-queue-capacity] keeping test dir: $TEST_DIR" >&2
  else
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup EXIT

if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
  SKIP_FRONTEND_BUILD=1 cargo build --bin bifrost
fi

START_ARGS=(--daemon --host 127.0.0.1 -p "$BIFROST_PORT" --unsafe-ssl --skip-cert-check --no-system-proxy)
if "$BIFROST_BIN" start --help | grep -q -- '--no-tray'; then
  START_ARGS+=(--no-tray)
fi
BIFROST_DATA_DIR="$TEST_DIR" "$BIFROST_BIN" start "${START_ARGS[@]}" >"$BIFROST_LOG" 2>&1

for _ in $(seq 1 180); do
  if curl -fsS --noproxy '*' "http://127.0.0.1:$BIFROST_PORT/_bifrost/api/proxy/address" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
curl -fsS --noproxy '*' "http://127.0.0.1:$BIFROST_PORT/_bifrost/api/proxy/address" >/dev/null

python3 - "$BIFROST_PORT" "$MOCK_LOG" "$REPO_DIR" <<'PY'
import json
import sys
import urllib.request

port, mock_log, repo_dir = sys.argv[1:4]
script = r'''
prompt=$(cat)
printf '%s\n' "$prompt" >>"$MOCK_QUEUE_LOG"
case "$prompt" in
  *queued-fifth*) ;;
  *) sleep 32 ;;
esac
printf '%s\n' \
  '{"type":"thread.started","thread_id":"thread-queue-mock"}' \
  '{"type":"turn.started"}' \
  '{"type":"item.completed","item":{"id":"final","type":"agent_message","text":"BIFROST_EXTERNAL_QUEUE_OK"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
'''
payload = {
    "version": 1,
    "defaultRunnerId": "queue-mock",
    "runners": {
        "queue-mock": {
            "enabled": True,
            "adapter": "mock",
            "adapterConfig": {
                "executable": "/bin/sh",
                "args": ["-c", script],
                "env": {"MOCK_QUEUE_LOG": mock_log},
                "timeoutSecs": 90,
            },
            "workDir": repo_dir,
            "injectBifrostTools": False,
            "skillPaths": [],
            "deliveryMode": "final_reply",
        }
    },
    "channels": {},
}
request = urllib.request.Request(
    f"http://127.0.0.1:{port}/_bifrost/api/im-gateway/chat/config",
    data=json.dumps(payload).encode(),
    headers={"content-type": "application/json"},
    method="PATCH",
)
with urllib.request.urlopen(request, timeout=30) as response:
    assert response.status == 200, response.read().decode()
PY

run_chat() {
  local session_key="$1"
  local message="$2"
  local output="$3"
  curl -fsS --noproxy '*' -X POST \
    "http://127.0.0.1:$BIFROST_PORT/_bifrost/api/im-gateway/chat" \
    -H 'content-type: application/json' \
    -d "{\"runnerId\":\"queue-mock\",\"sessionKey\":\"$session_key\",\"runtime\":\"external_cli\",\"message\":\"$message\"}" \
    >"$output"
}

for index in 1 2 3 4; do
  run_chat "queue-active-$index" "hold-active-$index" "$TEST_DIR/active-$index.json" &
  RUN_PIDS+=("$!")
done

for _ in $(seq 1 200); do
  if [[ -f "$MOCK_LOG" ]] && [[ "$(wc -l <"$MOCK_LOG")" -ge 4 ]]; then
    break
  fi
  sleep 0.05
done
[[ -f "$MOCK_LOG" ]]
[[ "$(wc -l <"$MOCK_LOG")" -eq 4 ]]

START_SECONDS="$SECONDS"
run_chat "queue-fifth" "queued-fifth" "$TEST_DIR/fifth.json"
ELAPSED_SECONDS=$((SECONDS - START_SECONDS))

for pid in "${RUN_PIDS[@]}"; do
  wait "$pid"
done
RUN_PIDS=()

grep -q 'BIFROST_EXTERNAL_QUEUE_OK' "$TEST_DIR/fifth.json"
if grep -q 'external CLI queue timed out' "$TEST_DIR/fifth.json"; then
  echo "fifth run hit the removed default queue deadline" >&2
  cat "$TEST_DIR/fifth.json" >&2
  exit 1
fi
if (( ELAPSED_SECONDS < 29 )); then
  echo "fifth run did not remain queued across the former 30-second deadline: ${ELAPSED_SECONDS}s" >&2
  exit 1
fi
[[ "$(wc -l <"$MOCK_LOG")" -eq 5 ]]

echo "[external-runner-queue-capacity] PASS (${ELAPSED_SECONDS}s queued wait)"

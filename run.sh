#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

NODE_BIN="${NODE_BIN:-node}"
ENTRY="${ENTRY:-$DIR/server.js}"

LOG="${LOG:-$DIR/logs.txt}"
PIDFILE="${PIDFILE:-$DIR/server.pid}"

ONB_DIR="${ONB_DIR:-$DIR/onb-server}"
AREAS_DIR="${AREAS_DIR:-$ONB_DIR/areas}"
GENERATED_DIR="${GENERATED_DIR:-$ONB_DIR/assets/generated}"
TRAINSTATION_SRC="${TRAINSTATION_SRC:-$ONB_DIR/assets/trainstation.tmx}"
TRAINSTATION_DEST="${TRAINSTATION_DEST:-$AREAS_DIR/trainstation.tmx}"

have_pid() {
  local p="${1:-}"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

reset_generated_content() {
  if [[ ! -f "$TRAINSTATION_SRC" ]]; then
    echo "Missing train station template: $TRAINSTATION_SRC" >&2
    exit 1
  fi

  echo "Resetting generated ONB content..."

  rm -rf "$AREAS_DIR"
  rm -rf "$GENERATED_DIR"

  mkdir -p "$AREAS_DIR"
  mkdir -p "$GENERATED_DIR"

  cp "$TRAINSTATION_SRC" "$TRAINSTATION_DEST"

  echo "Copied trainstation.tmx → $TRAINSTATION_DEST"
}

start_server() {
  if [[ -f "$PIDFILE" ]] && have_pid "$(cat "$PIDFILE" 2>/dev/null || true)"; then
    echo "Node server already running (pid $(cat "$PIDFILE"))."
    return 0
  fi

  reset_generated_content

  : > "$LOG"

  if command -v stdbuf >/dev/null 2>&1; then
    CMD=(stdbuf -oL -eL "$NODE_BIN" "$ENTRY")
  else
    CMD=("$NODE_BIN" "$ENTRY")
  fi

  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "${CMD[@]}" > >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG") 2>&1 &
  else
    nohup "${CMD[@]}" > >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG") 2>&1 &
  fi

  echo $! > "$PIDFILE"
  echo "Node server started (pid $(cat "$PIDFILE"))."
  echo "Logs → $LOG"
}

stop_server() {
  if [[ ! -f "$PIDFILE" ]]; then
    echo "No PID file; node server may not be running."
    return 0
  fi

  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"

  if ! have_pid "$pid"; then
    echo "PID $pid not running; cleaning up pidfile."
    rm -f "$PIDFILE"
    return 0
  fi

  kill -TERM -"${pid}" 2>/dev/null || true
  kill -TERM  "${pid}" 2>/dev/null || true

  for _ in {1..10}; do
    have_pid "$pid" || break
    sleep 0.3
  done

  if have_pid "$pid"; then
    echo "Force killing node server (pid $pid)..."
    kill -KILL -"${pid}" 2>/dev/null || true
    kill -KILL  "${pid}" 2>/dev/null || true

    for _ in {1..10}; do
      have_pid "$pid" || break
      sleep 0.2
    done
  fi

  rm -f "$PIDFILE"
  echo "Node server stopped."
}

status_server() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if have_pid "$pid"; then
      echo "Node server: running (pid $pid)"
    else
      echo "Node server: stopped (stale pidfile: $pid)"
    fi
  else
    echo "Node server: stopped"
  fi
}

case "${1:-}" in
  start|--daemon) start_server ;;
  stop)           stop_server ;;
  restart)        stop_server; start_server ;;
  status)         status_server ;;
  *)
    nohup bash "$0" start >/dev/null 2>&1 &
    echo "Starting node server in background. Logs → $LOG"
    ;;
esac

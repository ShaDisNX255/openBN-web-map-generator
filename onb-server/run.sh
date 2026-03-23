#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

SERVER="${SERVER:-$DIR/net_battle_server}"
PORT="${PORT:-8765}"

LOG="${LOG:-$DIR/logs.txt}"
PIDFILE="${PIDFILE:-$DIR/server.pid}"

have_pid() {
  local p="${1:-}"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

start_server() {
  if [[ -f "$PIDFILE" ]] && have_pid "$(cat "$PIDFILE" 2>/dev/null || true)"; then
    echo "ONB server already running (pid $(cat "$PIDFILE"))."
    return 0
  fi

  : > "$LOG"

  if command -v stdbuf >/dev/null 2>&1; then
    CMD=(stdbuf -oL -eL "$SERVER" -p "$PORT")
  else
    CMD=("$SERVER" -p "$PORT")
  fi

  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "${CMD[@]}" > >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG") 2>&1 &
  else
    nohup "${CMD[@]}" > >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG") 2>&1 &
  fi

  echo $! > "$PIDFILE"
  echo "ONB server started (pid $(cat "$PIDFILE"))."
  echo "Logs → $LOG"
}

stop_server() {
  if [[ ! -f "$PIDFILE" ]]; then
    echo "No PID file; ONB server may not be running."
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
    echo "Force killing ONB server (pid $pid)..."
    kill -KILL -"${pid}" 2>/dev/null || true
    kill -KILL  "${pid}" 2>/dev/null || true

    for _ in {1..10}; do
      have_pid "$pid" || break
      sleep 0.2
    done
  fi

  rm -f "$PIDFILE"
  echo "ONB server stopped."
}

status_server() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if have_pid "$pid"; then
      echo "ONB server: running (pid $pid)"
    else
      echo "ONB server: stopped (stale pidfile: $pid)"
    fi
  else
    echo "ONB server: stopped"
  fi
}

case "${1:-}" in
  start|--daemon) start_server ;;
  stop)           stop_server ;;
  restart)        stop_server; start_server ;;
  status)         status_server ;;
  *)
    nohup bash "$0" start >/dev/null 2>&1 &
    echo "Starting ONB server in background. Logs → $LOG"
    ;;
esac

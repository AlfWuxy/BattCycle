#!/bin/zsh
set -euo pipefail

# Codex 与开发者共用的单一构建入口。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BattCycle.app"
BINARY="$APP/Contents/MacOS/BattCycle"
ENGINE_PIDFILE="$HOME/Library/Application Support/BattCycle/run.pid"

build_app() {
  "$ROOT/packaging/package_app.sh"
}

stop_running_app() {
  local pid
  local command_line
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command_line="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == "$BINARY" || "$command_line" == "$BINARY "* ]]; then
      /bin/kill "$pid" 2>/dev/null || true
    fi
  done < <(/usr/bin/pgrep -x BattCycle 2>/dev/null || true)

  local attempt
  for attempt in {1..20}; do
    current_app_is_running || return 0
    /bin/sleep 0.1
  done
  echo "当前项目的 BattCycle 进程未能退出" >&2
  return 1
}

current_app_is_running() {
  local pid
  local command_line
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command_line="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == "$BINARY" || "$command_line" == "$BINARY "* ]]; then
      return 0
    fi
  done < <(/usr/bin/pgrep -x BattCycle 2>/dev/null || true)
  return 1
}

assert_no_active_cycle() {
  [[ -f "$ENGINE_PIDFILE" ]] || return 0
  local pid
  pid="$(<"$ENGINE_PIDFILE")"
  if [[ "$pid" == <1-> ]] && /bin/kill -0 "$pid" 2>/dev/null; then
    local command_line
    command_line="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *"battery_cycle_stress.sh"* ]]; then
      echo "检测到运行中的 BattCycle 循环 pid=$pid；请先从应用中停止循环。" >&2
      return 1
    fi
  fi
}

verify_launch() {
  assert_no_active_cycle
  build_app
  stop_running_app
  /usr/bin/open -n "$APP"

  local attempt
  for attempt in {1..20}; do
    if current_app_is_running; then
      echo "BattCycle 已启动：$APP"
      return 0
    fi
    /bin/sleep 0.25
  done

  echo "BattCycle 未能在 5 秒内启动" >&2
  return 1
}

case "${1:-run}" in
  run)
    assert_no_active_cycle
    build_app
    stop_running_app
    /usr/bin/open -n "$APP"
    ;;
  --verify)
    verify_launch
    ;;
  --debug)
    assert_no_active_cycle
    build_app
    stop_running_app
    exec /usr/bin/lldb "$BINARY"
    ;;
  --logs)
    exec /usr/bin/log stream --style compact --predicate 'subsystem == "org.alfwuxy.BattCycle"'
    ;;
  --telemetry)
    exec /usr/bin/log show --last 10m --style compact --predicate 'subsystem == "org.alfwuxy.BattCycle"'
    ;;
  *)
    echo "用法：$0 [run|--verify|--debug|--logs|--telemetry]" >&2
    exit 2
    ;;
esac

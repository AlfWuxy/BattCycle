#!/bin/zsh
set -euo pipefail

# 普通用户循环引擎：充电到上限，限时切断适配器并施加负载，降到下限后恢复。

umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
CLEANUP_MODE="${BATTCYCLE_CLEANUP_MODE:-0}"
SUPPORT="${BATTCYCLE_SUPPORT:-$HOME/Library/Application Support/BattCycle}"
LOG_DIR="${BATTCYCLE_LOG_DIR:-$HOME/Library/Logs/BattCycle}"
CONFIG_JSON="${BATTCYCLE_CONFIG:-$SUPPORT/config.json}"
CONFIG_TOOL="$HERE/battcycle_config.py"
BOUNDED_EXEC="$HERE/bounded_exec.py"
LOCK_TOOL="$HERE/engine_lock.py"
PROCESS_GROUP_EXEC="$HERE/process_group_exec.py"
PROCESS_GROUP_MARKER="$HERE/process_group_marker.py"
SYSTEM_PY="/usr/bin/python3"
BATT_TIMEOUT_SECONDS=4

BATT="${BATT:-/opt/homebrew/bin/batt}"
MLX_PYTHON="${MLX_PYTHON:-$HOME/Library/Application Support/BattCycle/venv/bin/python3}"
GPU_SCRIPT="${GPU_SCRIPT:-$HERE/mlx_gpu_stress.py}"
STRESS_NG="${STRESS_NG:-/opt/homebrew/bin/stress-ng}"
CAFFEINATE="${CAFFEINATE:-/usr/bin/caffeinate}"
PS_BIN="${BATTCYCLE_PS:-/bin/ps}"

# 每次切断最多 10 分钟，并且绝不越过本次运行截止时间。
MAX_ADAPTER_SAFETY_SECONDS=600

RUN_ID="$(date '+%Y%m%d_%H%M%S')"
LOG="${BATTCYCLE_CLEANUP_LOG:-$LOG_DIR/battcycle_${RUN_ID}.log}"
LATEST_LOG="$LOG_DIR/latest.log"
PIDFILE="$SUPPORT/run.pid"
LOCK_FILE="$SUPPORT/run.lock"
STATE="$SUPPORT/state.json"
STOP_FILE="$SUPPORT/stop.request"
GUARDIAN_HEARTBEAT="$SUPPORT/guardian.json"
STRESS_FAILURE_FILE="$SUPPORT/stress.failure"
GUARDIAN_PID="${BATTCYCLE_GUARDIAN_PID:-}"
GUARDIAN_PATH="${BATTCYCLE_GUARDIAN_PATH:-}"

UPPER_LIMIT="${BATTCYCLE_CLEANUP_UPPER_LIMIT:-}"
LOWER_LIMIT="${BATTCYCLE_CLEANUP_LOWER_LIMIT:-}"
GPU_SIZE=""
CPU_JOBS=""
POLL_SECONDS=""
STOP_AT_EPOCH=""

STRESS_PID="${BATTCYCLE_CLEANUP_STRESS_PID:-}"
CAFFEINATE_PID="${BATTCYCLE_CLEANUP_CAFFEINATE_PID:-}"
MARKER_PID="${BATTCYCLE_CLEANUP_MARKER_PID:-}"
ENGINE_PGID="${BATTCYCLE_CLEANUP_ENGINE_PGID:-}"
PHASE="${BATTCYCLE_CLEANUP_PHASE:-init}"
CLEANED_UP=0
pct=0
SNAPSHOT_SUMMARY=""
SNAPSHOT_PLUGGED=0
SNAPSHOT_ADAPTER=0
EXISTING_BATT_UPPER=0
LAST_ADAPTER_DURATION=""
FAILURE_MESSAGE="${BATTCYCLE_CLEANUP_FAILURE_MESSAGE:-}"
GUARDIAN_FAILURE=""
INSTANCE_TOKEN="${BATTCYCLE_INSTANCE_TOKEN:-}"
LOCK_DIR_FD="${BATTCYCLE_LOCK_DIR_FD:-}"
LOCK_FD="${BATTCYCLE_LOCK_FD:-}"
WORKER_ENGINE_PID=""

mkdir -p "$SUPPORT" "$LOG_DIR"

log() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  print -r -- "$line"
  print -r -- "$line" >> "$LOG"
}

die() {
  FAILURE_MESSAGE="$*"
  log "ERROR: $*"
  exit 1
}

require_executable() {
  local executable_path="$1"
  local label="$2"
  [[ -n "$executable_path" && -x "$executable_path" ]] || die "缺少可执行依赖 ${label}: ${executable_path:-未找到}"
}

verify_engine_lock() {
  local owner_pid="$1"
  if [[ "$LOCK_DIR_FD" != <3-> ]]; then
    return 1
  fi
  if [[ "$LOCK_FD" != <3-> ]]; then
    return 1
  fi
  if [[ "$owner_pid" != <2-> ]]; then
    return 1
  fi
  "$SYSTEM_PY" "$LOCK_TOOL" verify-held \
    --lock "$LOCK_FILE" \
    --dir-fd "$LOCK_DIR_FD" \
    --fd "$LOCK_FD" \
    --pid "$owner_pid" \
    --token "$INSTANCE_TOKEN" >/dev/null 2>&1
}

require_engine_lock() {
  verify_engine_lock "$1" || die "引擎未持有匹配的单实例内核锁"
}

load_config() {
  local output
  local -a values

  [[ -f "$CONFIG_TOOL" ]] || die "缺少配置解析器: $CONFIG_TOOL"
  if ! output="$("$SYSTEM_PY" "$CONFIG_TOOL" "$CONFIG_JSON")"; then
    die "配置校验失败: $CONFIG_JSON"
  fi
  values=("${(@f)output}")
  (( ${#values[@]} == 6 )) || die "配置解析器输出数量异常"

  UPPER_LIMIT="${values[1]}"
  LOWER_LIMIT="${values[2]}"
  GPU_SIZE="${values[3]}"
  CPU_JOBS="${values[4]}"
  POLL_SECONDS="${values[5]}"
  STOP_AT_EPOCH="${values[6]}"
}

batt_cmd() {
  "$SYSTEM_PY" "$BOUNDED_EXEC" --timeout "$BATT_TIMEOUT_SECONDS" -- "$BATT" "$@"
}

read_snapshot() {
  local payload
  local output
  local -a values

  payload="$(batt_cmd status --json)" || die "无法读取 batt 状态"
  if ! output="$(BATTCYCLE_STATUS_JSON="$payload" "$SYSTEM_PY" -I - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ["BATTCYCLE_STATUS_JSON"])
    battery = data["battery"]
    charging = data["charging"]
    percent = battery["currentChargePercent"]
    state = battery["state"]
    watts = battery["chargeRateWatts"]
    plugged = charging["pluggedIn"]
    adapter = charging["useAdapter"]
    existing_upper = data["configuration"]["upperLimitPercent"]
except (KeyError, TypeError, json.JSONDecodeError) as error:
    print("batt 状态结构无效: {}".format(error), file=sys.stderr)
    sys.exit(1)

if type(percent) is not int or not 0 <= percent <= 100:
    print("电量值无效", file=sys.stderr)
    sys.exit(1)
if not isinstance(state, str) or "\n" in state:
    print("电池状态值无效", file=sys.stderr)
    sys.exit(1)
if type(watts) not in (int, float):
    print("功率值无效", file=sys.stderr)
    sys.exit(1)
if type(plugged) is not bool or type(adapter) is not bool:
    print("供电状态值无效", file=sys.stderr)
    sys.exit(1)
if type(existing_upper) is not int or not 10 <= existing_upper <= 100:
    print("现有 batt 充电上限无效", file=sys.stderr)
    sys.exit(1)

print(percent)
print(state)
print(watts)
print(1 if plugged else 0)
print(1 if adapter else 0)
print(existing_upper)
PY
)"; then
    die "无法验证 batt 状态"
  fi

  values=("${(@f)output}")
  (( ${#values[@]} == 6 )) || die "batt 状态字段数量异常"
  pct="${values[1]}"
  SNAPSHOT_SUMMARY="State=${values[2]} Rate=${values[3]}W Plugged=${values[4]} Adapter=${values[5]}"
  SNAPSHOT_PLUGGED="${values[4]}"
  SNAPSHOT_ADAPTER="${values[5]}"
  EXISTING_BATT_UPPER="${values[6]}"
}

require_plugged_snapshot() {
  (( SNAPSHOT_PLUGGED == 1 )) || die "运行中检测到电源断开，正在停止负载并尝试恢复适配器"
}

adapter_power_ready() {
  local payload
  payload="$(batt_cmd status --json)" || return 1
  # EXIT 清理阶段不从标准输入加载 Python，避免信号竞争时 heredoc 阻塞恢复流程。
  BATTCYCLE_STATUS_JSON="$payload" "$SYSTEM_PY" -I -c '
import json
import os
import sys

try:
    charging = json.loads(os.environ["BATTCYCLE_STATUS_JSON"])["charging"]
    enabled = charging["useAdapter"]
    plugged = charging["pluggedIn"]
except (KeyError, TypeError, json.JSONDecodeError):
    sys.exit(1)
sys.exit(0 if enabled is True and plugged is True else 1)
'
}

write_state() {
  local now
  local iso
  local stress_pgid="${STRESS_PID:-0}"
  now="$(date '+%s')"
  iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  "$SYSTEM_PY" -I - "$STATE" "$PHASE" "$pct" "$$" "$STOP_AT_EPOCH" \
    "$UPPER_LIMIT" "$LOWER_LIMIT" "$iso" "$now" "$LOG" "1" "" \
    "$stress_pgid" <<'PY'
import json
import os
import secrets
import stat
import sys

(
    path,
    phase,
    percent,
    pid,
    stop_at,
    upper,
    lower,
    updated_at,
    updated_epoch,
    log_path,
    running,
    error_text,
    stress_pgid,
) = sys.argv[1:]

state = {
    "phase": phase,
    "percent": int(percent),
    "pid": int(pid),
    "stopAtEpoch": int(stop_at),
    "upper": int(upper),
    "lower": int(lower),
    "updatedAt": updated_at,
    "updatedEpoch": int(updated_epoch),
    "log": log_path,
    "running": running == "1",
    "error": error_text or None,
    "stressPgid": int(stress_pgid),
}
encoded = (json.dumps(state, indent=2, sort_keys=True) + "\n").encode("utf-8")
parent = os.path.dirname(path)
name = os.path.basename(path)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
directory_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
directory = os.open(parent, directory_flags)
temporary = None
try:
    parent_stat = os.fstat(directory)
    if not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != os.getuid():
        raise OSError("state 父目录所有者无效")
    if stat.S_IMODE(parent_stat.st_mode) & 0o077:
        raise OSError("state 父目录必须为私有目录")
    for _ in range(16):
        candidate = ".{}.tmp.{}.{}".format(name, os.getpid(), secrets.token_hex(8))
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(candidate, flags, 0o600, dir_fd=directory)
            temporary = candidate
            break
        except FileExistsError:
            continue
    else:
        raise OSError("无法创建随机 state 临时文件")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError("state 临时路径必须是普通文件")
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
    temporary = None
    os.fsync(directory)
finally:
    if temporary is not None:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
    os.close(directory)
PY
}

write_idle_state() {
  local error_text="${1:-}"
  local now
  local iso
  local phase="idle"
  local stress_pgid="${STRESS_PID:-0}"
  if [[ -n "$error_text" ]]; then
    phase="failed"
  fi
  now="$(date '+%s')"
  iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  "$SYSTEM_PY" -I - "$STATE" "$phase" "0" "0" "0" "$UPPER_LIMIT" \
    "$LOWER_LIMIT" "$iso" "$now" "$LOG" "0" "$error_text" \
    "$stress_pgid" <<'PY'
import json
import os
import secrets
import stat
import sys

(
    path,
    phase,
    percent,
    pid,
    stop_at,
    upper,
    lower,
    updated_at,
    updated_epoch,
    log_path,
    running,
    error_text,
    stress_pgid,
) = sys.argv[1:]

state = {
    "phase": phase,
    "percent": int(percent),
    "pid": int(pid),
    "stopAtEpoch": int(stop_at),
    "upper": int(upper),
    "lower": int(lower),
    "updatedAt": updated_at,
    "updatedEpoch": int(updated_epoch),
    "log": log_path,
    "running": running == "1",
    "error": error_text or None,
    "stressPgid": int(stress_pgid),
}
encoded = (json.dumps(state, indent=2, sort_keys=True) + "\n").encode("utf-8")
parent = os.path.dirname(path)
name = os.path.basename(path)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
directory_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
directory = os.open(parent, directory_flags)
temporary = None
try:
    parent_stat = os.fstat(directory)
    if not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != os.getuid():
        raise OSError("state 父目录所有者无效")
    if stat.S_IMODE(parent_stat.st_mode) & 0o077:
        raise OSError("state 父目录必须为私有目录")
    for _ in range(16):
        candidate = ".{}.tmp.{}.{}".format(name, os.getpid(), secrets.token_hex(8))
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(candidate, flags, 0o600, dir_fd=directory)
            temporary = candidate
            break
        except FileExistsError:
            continue
    else:
        raise OSError("无法创建随机 state 临时文件")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError("state 临时路径必须是普通文件")
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
    temporary = None
    os.fsync(directory)
finally:
    if temporary is not None:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
    os.close(directory)
PY
}

check_stop_time() {
  if (( STOP_AT_EPOCH == 0 )); then
    return 0
  fi
  local now
  now="$(date '+%s')"
  if (( now >= STOP_AT_EPOCH )); then
    log "到达计划停止时间 stop_at=${STOP_AT_EPOCH}"
    return 1
  fi
}

check_stop_request() {
  if [[ -f "$STOP_FILE" ]]; then
    log "收到用户停止请求"
    # 保留到 cleanup，让与 controller TERM 竞态的 EXIT trap 仍可鉴别请求式停止。
    return 1
  fi
}

check_guardian() {
  local command_line
  local validation_output

  if [[ "$GUARDIAN_PID" != <1-> || "$GUARDIAN_PID" -le 1 ]]; then
    GUARDIAN_FAILURE="守护 PID 无效"
    return 1
  fi
  kill -0 "$GUARDIAN_PID" 2>/dev/null || {
    GUARDIAN_FAILURE="BattCycle App 已退出"
    return 1
  }
  command_line="$(/bin/ps -p "$GUARDIAN_PID" -o command= 2>/dev/null || true)"
  if [[ "$command_line" != "$GUARDIAN_PATH" && "$command_line" != "$GUARDIAN_PATH "* ]]; then
    GUARDIAN_FAILURE="BattCycle App 身份不匹配"
    return 1
  fi

  if ! validation_output="$($SYSTEM_PY -I - "$GUARDIAN_HEARTBEAT" "$GUARDIAN_PID" "$GUARDIAN_PATH" <<\PY
import json
import os
import stat
import sys
import time

path, expected_pid, expected_path = sys.argv[1:]
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
try:
    descriptor = os.open(path, flags)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 4096:
        raise ValueError("心跳文件类型或大小无效")
    with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, ValueError, json.JSONDecodeError) as error:
    print("无法安全读取 App 心跳: {}".format(error))
    sys.exit(1)

now = int(time.time())
if payload.get("pid") != int(expected_pid):
    print("App 心跳 PID 不匹配")
    sys.exit(1)
if payload.get("executablePath") != expected_path:
    print("App 心跳路径不匹配")
    sys.exit(1)
updated = payload.get("updatedEpoch")
if type(updated) is not int or updated > now + 5 or now - updated > 10:
    print("App 心跳超过 10 秒未更新")
    sys.exit(1)
thermal = payload.get("thermalState")
if thermal not in ("nominal", "fair"):
    print("macOS 热状态不安全: {}".format(thermal))
    sys.exit(1)
PY
)"; then
    GUARDIAN_FAILURE="${validation_output:-App 心跳验证失败}"
    return 1
  fi
  return 0
}

require_guardian() {
  check_guardian || die "安全守护触发停止: $GUARDIAN_FAILURE"
}

collect_descendants() {
  local parent="$1"
  local child
  local children_text
  local -a children

  children_text="$(/usr/bin/pgrep -P "$parent" 2>/dev/null || true)"
  children=("${(@f)children_text}")
  for child in "${children[@]}"; do
    if [[ -n "$child" ]]; then
      print -- "$child"
      collect_descendants "$child"
    fi
  done
}

process_is_active() {
  local target_pid="$1"
  local process_state
  [[ "$target_pid" == <1-> ]] || return 1
  /bin/kill -0 "$target_pid" 2>/dev/null || return 1
  if ! process_state="$(/bin/ps -p "$target_pid" -o state= 2>/dev/null | /usr/bin/tr -d '[:space:]')"; then
    # 查询失败时按仍存活处理，避免把活进程交给无界 wait。
    return 0
  fi
  [[ -z "$process_state" || "$process_state" != Z* ]]
}

process_group_is_active() {
  local group_id="$1"
  local process_table
  [[ "$group_id" == <2-> ]] || return 1
  /bin/kill -0 -- "-$group_id" 2>/dev/null || return 1
  if ! process_table="$(/bin/ps -g "$group_id" -o pgid=,state= 2>/dev/null)"; then
    # 组在定向查询失败后仍可被探测时按存活处理，避免误判并复用 PID。
    /bin/kill -0 -- "-$group_id" 2>/dev/null && return 0
    return 1
  fi
  print -r -- "$process_table" | /usr/bin/awk -v target="$group_id" '
    $1 == target && substr($2, 1, 1) != "Z" { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

process_group_or_leader_is_active() {
  local leader_pid="$1"
  process_group_is_active "$leader_pid" || process_is_active "$leader_pid"
}

marker_is_active() {
  local marker_pid="$1"
  local expected_group="$2"
  local expected_role="$3"
  local command_line
  local expected_command
  local marker_group
  [[ "$expected_role" == "engine" || "$expected_role" == "workload" ]] || return 1
  process_is_active "$marker_pid" || return 1
  marker_group="$(/bin/ps -p "$marker_pid" -o pgid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
  [[ "$marker_group" == "$expected_group" ]] || return 1
  command_line="$(/bin/ps -p "$marker_pid" -o command= 2>/dev/null || true)"
  expected_command="$PROCESS_GROUP_MARKER --role $expected_role --instance-token $INSTANCE_TOKEN"
  [[ "$command_line" == "$expected_command" || "$command_line" == *" $expected_command" ]]
}

start_engine_marker() {
  "$SYSTEM_PY" "$PROCESS_GROUP_MARKER" \
    --role engine --instance-token "$INSTANCE_TOKEN" &
  MARKER_PID=$!
  for _marker_attempt in {1..20}; do
    marker_is_active "$MARKER_PID" "$ENGINE_PGID" engine && return 0
    process_is_active "$MARKER_PID" || break
    /bin/sleep 0.05
  done
  reap_if_inactive "$MARKER_PID" || true
  MARKER_PID=""
  die "引擎进程组身份标记无法启动"
}

require_engine_marker() {
  marker_is_active "$MARKER_PID" "$ENGINE_PGID" engine || \
    die "引擎进程组身份标记意外退出"
}

process_group_has_workload_marker() {
  local group_id="$1"
  local process_table
  [[ "$group_id" == <2-> ]] || return 1
  process_table="$("$PS_BIN" -g "$group_id" -o uid=,pgid=,state=,command= 2>/dev/null)" \
    || return 1
  print -r -- "$process_table" | /usr/bin/awk \
    -v current_euid="$EUID" \
    -v target="$group_id" \
    -v expected="$PROCESS_GROUP_MARKER --role workload --instance-token $INSTANCE_TOKEN" '
      $1 ~ /^[0-9]+$/ && $1 == current_euid &&
      $2 == target && substr($3, 1, 1) != "Z" {
        line = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", line)
        if (line == expected ||
            (length(line) > length(expected) &&
             substr(line, length(line) - length(expected), 1) == " " &&
             substr(line, length(line) - length(expected) + 1) == expected)) {
          matches++
        }
      }
      END { exit(matches == 1 ? 0 : 1) }
    '
}

worker_engine_owner_is_current() {
  local command_line
  local owner_group
  [[ "$WORKER_ENGINE_PID" == <2-> ]] || return 1
  process_is_active "$WORKER_ENGINE_PID" || return 1
  owner_group="$(/bin/ps -p "$WORKER_ENGINE_PID" -o pgid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
  [[ "$owner_group" == "$WORKER_ENGINE_PID" ]] || return 1
  command_line="$(/bin/ps -p "$WORKER_ENGINE_PID" -o command= 2>/dev/null || true)"
  [[ "$command_line" == "/bin/zsh $HERE/battery_cycle_stress.sh --battcycle-instance-token=$INSTANCE_TOKEN" ]]
}

require_worker_engine_owner() {
  if ! worker_engine_owner_is_current \
    || ! verify_engine_lock "$WORKER_ENGINE_PID"; then
    record_stress_failure "引擎 leader 已退出或身份不匹配，拒绝启动或继续放电负载"
    return 1
  fi
}

wait_for_test_pre_marker_barrier() {
  local barrier_path="${BATTCYCLE_TEST_PRE_MARKER_BARRIER_FILE:-}"
  [[ -n "$barrier_path" ]] || return 0
  [[ "$barrier_path" == "$SUPPORT/test.pre-marker.barrier" ]] || return 1
  log "TEST: workload 已到达 pre-marker barrier"
  while [[ -e "$barrier_path" ]]; do
    require_worker_engine_owner || return 1
    /bin/sleep 0.05
  done
  return 0
}

reap_if_inactive() {
  local target_pid="$1"
  if process_is_active "$target_pid"; then
    return 1
  fi
  wait "$target_pid" 2>/dev/null || true
  return 0
}

terminate_tree() {
  local parent="$1"
  local attempt
  local target
  local all_stopped
  local -a targets
  [[ "$parent" == <1-> ]] || return 0

  targets=("$parent" "${(@f)$(collect_descendants "$parent")}")
  for target in "${targets[@]}"; do
    process_is_active "$target" && /bin/kill -TERM "$target" 2>/dev/null || true
  done
  for attempt in {1..20}; do
    all_stopped=1
    for target in "${targets[@]}"; do
      if process_is_active "$target"; then
        all_stopped=0
      fi
    done
    (( all_stopped == 1 )) && break
    /bin/sleep 0.1
  done
  if (( all_stopped == 0 )); then
    for target in "${targets[@]}"; do
      process_is_active "$target" && /bin/kill -KILL "$target" 2>/dev/null || true
    done
    for attempt in {1..20}; do
      all_stopped=1
      for target in "${targets[@]}"; do
        if process_is_active "$target"; then
          all_stopped=0
        fi
      done
      (( all_stopped == 1 )) && break
      /bin/sleep 0.1
    done
  fi
  if (( all_stopped == 1 )); then
    reap_if_inactive "$parent" || true
  fi
  (( all_stopped == 1 ))
}

terminate_marker() {
  local marker_pid="$1"
  local expected_group="$2"
  local expected_role="$3"
  local attempt
  if ! process_is_active "$marker_pid"; then
    reap_if_inactive "$marker_pid" || true
    return 0
  fi
  marker_is_active "$marker_pid" "$expected_group" "$expected_role" || return 1
  /bin/kill -HUP "$marker_pid" 2>/dev/null || true
  for attempt in {1..20}; do
    process_is_active "$marker_pid" || break
    /bin/sleep 0.1
  done
  if process_is_active "$marker_pid"; then
    marker_is_active "$marker_pid" "$expected_group" "$expected_role" || return 1
    /bin/kill -KILL "$marker_pid" 2>/dev/null || true
    for attempt in {1..20}; do
      process_is_active "$marker_pid" || break
      /bin/sleep 0.1
    done
  fi
  process_is_active "$marker_pid" && return 1
  reap_if_inactive "$marker_pid" || true
  return 0
}

terminate_process_group() {
  local group_id="$1"
  local attempt
  [[ "$group_id" == <2-> ]] || return 0

  /bin/kill -TERM -- "-$group_id" 2>/dev/null || true
  for attempt in {1..30}; do
    process_group_is_active "$group_id" || break
    /bin/sleep 0.1
  done
  if process_group_is_active "$group_id"; then
    /bin/kill -KILL -- "-$group_id" 2>/dev/null || true
    for attempt in {1..30}; do
      process_group_is_active "$group_id" || break
      /bin/sleep 0.1
    done
  fi
  process_group_is_active "$group_id" && return 1
  return 0
}

terminate_authenticated_workload_group() {
  local group_id="$1"
  local attempt
  [[ "$group_id" == <2-> ]] || return 0
  process_group_has_workload_marker "$group_id" || return 1
  /bin/kill -TERM -- "-$group_id" 2>/dev/null || true
  for attempt in {1..30}; do
    process_group_is_active "$group_id" || break
    /bin/sleep 0.1
  done
  if process_group_is_active "$group_id"; then
    # TERM 后必须用当前实例 token 重新认证 marker，才能 KILL 整组。
    process_group_has_workload_marker "$group_id" || return 1
    /bin/kill -KILL -- "-$group_id" 2>/dev/null || true
    for attempt in {1..30}; do
      process_group_is_active "$group_id" || break
      /bin/sleep 0.1
    done
  fi
  process_group_is_active "$group_id" && return 1
  return 0
}

record_stress_failure() {
  local message="$1"
  "$SYSTEM_PY" -I - "$STRESS_FAILURE_FILE" "$message" <<'PY'
import os
import secrets
import stat
import sys

path, message = sys.argv[1:]
encoded = (message + "\n").encode("utf-8")
parent = os.path.dirname(path)
name = os.path.basename(path)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
directory_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
directory = os.open(parent, directory_flags)
temporary = None
try:
    parent_stat = os.fstat(directory)
    if not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != os.getuid():
        raise OSError("压力失败文件父目录所有者无效")
    if stat.S_IMODE(parent_stat.st_mode) & 0o077:
        raise OSError("压力失败文件父目录必须为私有目录")
    for _ in range(16):
        candidate = ".{}.tmp.{}.{}".format(name, os.getpid(), secrets.token_hex(8))
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(candidate, flags, 0o600, dir_fd=directory)
            temporary = candidate
            break
        except FileExistsError:
            continue
    else:
        raise OSError("无法创建随机压力失败临时文件")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError("压力失败临时路径必须是普通文件")
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
    temporary = None
    os.fsync(directory)
finally:
    if temporary is not None:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
    os.close(directory)
PY
}

cpu_worker_group() {
  exec "$STRESS_NG" --cpu "$CPU_JOBS" --cpu-method all --stream 3 >> "$LOG" 2>&1
}

stress_worker_loop() {
  local gpu_pid=""
  local cpu_pid=""
  local gpu_status=0
  local started_at=0
  local elapsed=0
  local workload_marker_pid=""
  local worker_group="$$"

  require_worker_engine_owner || return 1
  wait_for_test_pre_marker_barrier || {
    record_stress_failure "pre-marker 测试 barrier 无效或引擎 leader 已退出"
    return 1
  }
  require_worker_engine_owner || return 1
  "$SYSTEM_PY" "$PROCESS_GROUP_MARKER" \
    --role workload --instance-token "$INSTANCE_TOKEN" &
  workload_marker_pid=$!
  for _marker_attempt in {1..20}; do
    marker_is_active "$workload_marker_pid" "$worker_group" workload && break
    process_is_active "$workload_marker_pid" || break
    /bin/sleep 0.05
  done
  if ! marker_is_active "$workload_marker_pid" "$worker_group" workload; then
    record_stress_failure "放电负载身份标记无法启动"
    return 1
  fi

  trap '
    _worker_status=$?
    trap - EXIT INT TERM HUP
    [[ -n "$gpu_pid" ]] && terminate_tree "$gpu_pid"
    [[ -n "$cpu_pid" ]] && terminate_tree "$cpu_pid"
    [[ -n "$workload_marker_pid" ]] && \
      terminate_marker "$workload_marker_pid" "$worker_group" workload
    exit "$_worker_status"
  ' EXIT
  trap 'exit 130' INT TERM HUP

  while true; do
    require_worker_engine_owner || return 1
    if ! marker_is_active "$workload_marker_pid" "$worker_group" workload; then
      record_stress_failure "放电负载身份标记意外退出"
      return 1
    fi
    if [[ -n "$cpu_pid" ]] && ! process_is_active "$cpu_pid"; then
      wait "$cpu_pid" 2>/dev/null || true
      record_stress_failure "CPU 负载进程提前退出"
      return 1
    fi
    if [[ -z "$cpu_pid" ]]; then
      require_worker_engine_owner || return 1
      cpu_worker_group &
      cpu_pid=$!
      log "CPU 负载已启动 pid=${cpu_pid} jobs=${CPU_JOBS}"
    fi

    log "MLX 负载片段开始 size=${GPU_SIZE}"
    require_worker_engine_owner || return 1
    started_at="$(date '+%s')"
    "$MLX_PYTHON" "$GPU_SCRIPT" --size "$GPU_SIZE" --seconds 600 >> "$LOG" 2>&1 &
    gpu_pid=$!
    gpu_status=0
    while process_is_active "$gpu_pid"; do
      if ! require_worker_engine_owner; then
        terminate_tree "$gpu_pid" || true
        return 1
      fi
      if ! marker_is_active "$workload_marker_pid" "$worker_group" workload; then
        terminate_tree "$gpu_pid" || true
        record_stress_failure "放电负载身份标记意外退出"
        return 1
      fi
      if ! process_is_active "$cpu_pid"; then
        terminate_tree "$gpu_pid" || true
        record_stress_failure "CPU 负载进程提前退出"
        return 1
      fi
      /bin/sleep 1
    done
    wait "$gpu_pid" 2>/dev/null || gpu_status=$?
    elapsed=$(( $(date '+%s') - started_at ))
    gpu_pid=""
    if (( gpu_status != 0 || elapsed < 5 )); then
      terminate_tree "$cpu_pid" || true
      cpu_pid=""
      record_stress_failure "MLX 负载异常退出 status=${gpu_status} elapsed=${elapsed}s"
      return 1
    fi
  done
}

stress_worker_main() {
  local owner_pid
  local worker_group
  (( $# == 7 )) || die "放电负载内部参数数量无效"
  [[ "$1" == "--battcycle-stress-worker" ]] || die "放电负载内部模式无效"
  validate_instance_token "$2"
  [[ "$3" == --engine-pid=<2-> ]] || die "放电负载 engine PID 无效"
  [[ "$4" == --gpu-size=<-> ]] || die "放电负载 GPU 参数无效"
  [[ "$5" == --cpu-jobs=<-> ]] || die "放电负载 CPU 参数无效"
  [[ "$6" == --log=/* && "$6" != *[[:cntrl:]]* ]] || die "放电负载日志路径无效"
  [[ "$7" == --failure-file=/* && "$7" != *[[:cntrl:]]* ]] || die "放电负载失败路径无效"

  owner_pid="${3#--engine-pid=}"
  WORKER_ENGINE_PID="$owner_pid"
  GPU_SIZE="${4#--gpu-size=}"
  CPU_JOBS="${5#--cpu-jobs=}"
  LOG="${6#--log=}"
  STRESS_FAILURE_FILE="${7#--failure-file=}"
  (( GPU_SIZE == 2048 || GPU_SIZE == 4096 || GPU_SIZE == 8192 )) || \
    die "放电负载 GPU 参数超出允许范围"
  (( CPU_JOBS >= 1 && CPU_JOBS <= 16 )) || die "放电负载 CPU 参数超出允许范围"
  [[ "${LOG:h}" == "$LOG_DIR" ]] || die "放电负载日志必须位于私有日志目录"
  [[ "$STRESS_FAILURE_FILE" == "$SUPPORT/stress.failure" ]] || \
    die "放电负载失败路径与运行目录不匹配"

  require_executable "$SYSTEM_PY" "/usr/bin/python3"
  require_executable "$LOCK_TOOL" "engine_lock.py"
  require_executable "$PROCESS_GROUP_MARKER" "process_group_marker.py"
  require_executable "$MLX_PYTHON" "包含 mlx 的 Python"
  require_executable "$GPU_SCRIPT" "MLX 负载脚本"
  require_executable "$STRESS_NG" "stress-ng"
  require_engine_lock "$owner_pid"
  worker_group="$(/bin/ps -p $$ -o pgid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
  [[ "$worker_group" == "$$" ]] || die "放电负载必须在独立进程组中运行"
  stress_worker_loop
}

start_stress() {
  require_engine_lock "$$"
  if [[ -f "$STRESS_FAILURE_FILE" ]]; then
    die "放电负载失败: $(<"$STRESS_FAILURE_FILE")"
  fi
  if [[ -n "$STRESS_PID" ]] && process_group_is_active "$STRESS_PID"; then
    process_group_has_workload_marker "$STRESS_PID" || \
      die "放电负载身份标记已丢失"
    return 0
  fi
  if [[ -n "$STRESS_PID" ]]; then
    reap_if_inactive "$STRESS_PID" || true
    die "放电负载进程意外退出"
  fi
  "$SYSTEM_PY" "$PROCESS_GROUP_EXEC" -- \
    /bin/zsh "$HERE/battery_cycle_stress.sh" \
    --battcycle-stress-worker \
    "--battcycle-instance-token=$INSTANCE_TOKEN" \
    "--engine-pid=$$" \
    "--gpu-size=$GPU_SIZE" \
    "--cpu-jobs=$CPU_JOBS" \
    "--log=$LOG" \
    "--failure-file=$STRESS_FAILURE_FILE" &
  STRESS_PID=$!
  for _stress_attempt in {1..30}; do
    process_group_has_workload_marker "$STRESS_PID" && break
    # process_group_exec 刚 fork 后可能尚未完成 setsid，先用 leader PID 覆盖该短窗口。
    process_is_active "$STRESS_PID" || break
    /bin/sleep 0.1
  done
  if ! process_group_has_workload_marker "$STRESS_PID"; then
    # 身份标记尚未通过时只收敛刚启动的子进程树，不向未认证 PGID 发送信号。
    terminate_tree "$STRESS_PID" || true
    die "放电负载独立进程组无法通过身份验证"
  fi
  log "放电负载已启动 pgid=${STRESS_PID}"
}

check_stress_health() {
  [[ "$PHASE" == "discharging" ]] || return 0
  if [[ -f "$STRESS_FAILURE_FILE" ]]; then
    die "放电负载失败: $(<"$STRESS_FAILURE_FILE")"
  fi
  if [[ -n "$STRESS_PID" ]] && ! process_is_active "$STRESS_PID"; then
    reap_if_inactive "$STRESS_PID" || true
    die "放电负载进程意外退出"
  fi
  if [[ -n "$STRESS_PID" ]] && ! process_group_has_workload_marker "$STRESS_PID"; then
    die "放电负载身份标记意外退出"
  fi
}

stop_stress() {
  local settle_attempt
  if [[ -n "$STRESS_PID" ]] && process_group_is_active "$STRESS_PID"; then
    if ! process_group_has_workload_marker "$STRESS_PID"; then
      # controller 可能已经 TERM 该组；marker 由 worker 用 HUP 先行收敛时，
      # 只等待整组自然静默，仍不向未认证 PGID 发信号。
      for settle_attempt in {1..20}; do
        process_group_is_active "$STRESS_PID" || break
        /bin/sleep 0.1
      done
      if process_group_is_active "$STRESS_PID"; then
        log "ERROR: 放电负载进程组身份认证失败，拒绝向 pgid=${STRESS_PID} 发送信号"
        return 1
      fi
      reap_if_inactive "$STRESS_PID" || true
      STRESS_PID=""
      return 0
    fi
    log "停止放电负载 pgid=${STRESS_PID}"
    if ! terminate_authenticated_workload_group "$STRESS_PID"; then
      return 1
    fi
    reap_if_inactive "$STRESS_PID" || true
  elif [[ -n "$STRESS_PID" ]] && ! reap_if_inactive "$STRESS_PID"; then
    return 1
  fi
  STRESS_PID=""
  return 0
}

disable_adapter_safely() {
  local now
  local remaining
  local duration

  require_engine_lock "$$"
  now="$(date '+%s')"
  remaining=$((STOP_AT_EPOCH - now))
  if (( remaining <= 0 )); then
    return 2
  fi
  duration="$remaining"
  if (( duration > MAX_ADAPTER_SAFETY_SECONDS )); then
    duration="$MAX_ADAPTER_SAFETY_SECONDS"
  fi
  LAST_ADAPTER_DURATION="${duration}s"
  batt_cmd adapter disable --for="$LAST_ADAPTER_DURATION" >> "$LOG" 2>&1
}

refresh_adapter_window() {
  local result=0
  disable_adapter_safely || result=$?
  (( result == 0 )) && return 0
  if (( result == 2 )); then
    log "适配器切断窗口已到总截止时间"
    return 1
  fi
  die "无法设置限时适配器切断窗口"
}

restore_normal_power() {
  local failed=0

  if ! batt_cmd adapter enable >> "$LOG" 2>&1; then
    log "ERROR: 适配器恢复命令失败"
    failed=1
  fi
  if ! adapter_power_ready; then
    log "ERROR: 适配器恢复后验证失败；电源未接入或适配器未启用"
    failed=1
  fi
  return "$failed"
}

cleanup() {
  local failed=0
  local workloads_stopped=1
  local terminal_error="$FAILURE_MESSAGE"
  if (( CLEANED_UP == 1 )); then
    return 0
  fi
  CLEANED_UP=1

  log "清理开始 phase=${PHASE}"
  # 优先恢复外部电源，再处理有界的本地负载终止。
  if ! restore_normal_power; then
    failed=1
    terminal_error="适配器恢复失败，请检查日志并手动恢复"
  fi
  if ! stop_stress; then
    failed=1
    workloads_stopped=0
    terminal_error="无法确认放电负载已停止"
  fi

  if [[ -n "$CAFFEINATE_PID" ]] && process_is_active "$CAFFEINATE_PID"; then
    if ! terminate_tree "$CAFFEINATE_PID"; then
      failed=1
      workloads_stopped=0
    else
      CAFFEINATE_PID=""
    fi
  elif [[ -n "$CAFFEINATE_PID" ]]; then
    if ! reap_if_inactive "$CAFFEINATE_PID"; then
      failed=1
      workloads_stopped=0
    else
      CAFFEINATE_PID=""
    fi
  fi

  # 引擎组标记持有锁文件描述符，必须在其他负载收敛后最后停止。
  if [[ -n "$MARKER_PID" ]] && process_is_active "$MARKER_PID"; then
    if ! terminate_marker "$MARKER_PID" "$ENGINE_PGID" engine; then
      failed=1
      workloads_stopped=0
      terminal_error="无法确认引擎身份标记已停止"
    else
      MARKER_PID=""
    fi
  elif [[ -n "$MARKER_PID" ]]; then
    if ! reap_if_inactive "$MARKER_PID"; then
      failed=1
      workloads_stopped=0
      terminal_error="无法确认引擎身份标记已停止"
    else
      MARKER_PID=""
    fi
  fi

  rm -f "$STOP_FILE"
  if (( workloads_stopped == 1 )); then
    rm -f "$PIDFILE" "$STRESS_FAILURE_FILE"
  else
    log "ERROR: 保留 PID 记录，供 Stop 或 Restore 继续收敛残余进程组"
  fi
  write_idle_state "$terminal_error" || failed=1

  if (( failed == 0 )) && [[ -z "$terminal_error" ]]; then
    log "清理完成，适配器已验证恢复"
  elif (( failed == 0 )); then
    log "ERROR: 引擎以失败状态结束: $terminal_error"
  else
    log "ERROR: 清理未完整成功"
  fi
  return "$failed"
}

on_exit() {
  BATTCYCLE_EXIT_STATUS=$?
  local original_status="$BATTCYCLE_EXIT_STATUS"
  local cleanup_child_status=1
  local cleanup_child_pid=""
  local cleanup_child_reaped=0
  local cleanup_child_timed_out=0
  local cleanup_child_uncontained=0
  local cleanup_poll_limit=0
  local cleanup_poll_count=0
  local cleanup_result=0
  local cleanup_timeout="${BATTCYCLE_TEST_CLEANUP_TIMEOUT_SECONDS:-18}"
  local fallback_child_pid=""
  local fallback_child_status=1
  local fallback_child_reaped=0
  local fallback_poll_count=0
  local fallback_poll_limit=180
  local requested_stop=0
  trap - EXIT INT TERM HUP
  # zsh 在 EXIT trap 中可以负信号数表示原始终止原因，先规范化为 shell 退出码。
  case "$original_status" in
    -1) original_status=129 ;;
    -2) original_status=130 ;;
    -15) original_status=143 ;;
  esac
  # controller 先安全写入 stop.request；zsh 可能以信号原始退出码进入 EXIT trap。
  if [[ -f "$STOP_FILE" ]] \
    && (( original_status == 129 || original_status == 130 || original_status == 143 )); then
    requested_stop=1
  fi
  if (( original_status != 0 && original_status != 130 && requested_stop == 0 )) \
    && [[ -z "$FAILURE_MESSAGE" ]]; then
    FAILURE_MESSAGE="引擎异常退出，请检查日志"
  fi
  if (( original_status == 0 )) && [[ -n "$FAILURE_MESSAGE" ]]; then
    original_status=1
  fi

  export BATTCYCLE_CLEANUP_MODE=1
  export BATTCYCLE_CLEANUP_ORIGINAL_STATUS="$original_status"
  export BATTCYCLE_CLEANUP_STRESS_PID="$STRESS_PID"
  export BATTCYCLE_CLEANUP_CAFFEINATE_PID="$CAFFEINATE_PID"
  export BATTCYCLE_CLEANUP_MARKER_PID="$MARKER_PID"
  export BATTCYCLE_CLEANUP_ENGINE_PGID="$ENGINE_PGID"
  export BATTCYCLE_CLEANUP_PHASE="$PHASE"
  export BATTCYCLE_CLEANUP_FAILURE_MESSAGE="$FAILURE_MESSAGE"
  export BATTCYCLE_CLEANUP_UPPER_LIMIT="$UPPER_LIMIT"
  export BATTCYCLE_CLEANUP_LOWER_LIMIT="$LOWER_LIMIT"
  export BATTCYCLE_CLEANUP_LOG="$LOG"

  if [[ "$cleanup_timeout" != <1-> ]] || (( cleanup_timeout > 18 )); then
    cleanup_timeout=18
  fi
  set +e
  if [[ "${BATTCYCLE_TEST_FAIL_CLEANUP_CHILD:-0}" != "1" ]]; then
    "$SYSTEM_PY" "$PROCESS_GROUP_EXEC" -- \
        /bin/zsh "$HERE/battery_cycle_stress.sh" \
        --battcycle-cleanup \
        "--battcycle-instance-token=$INSTANCE_TOKEN" \
        "--engine-pid=$$" &
    cleanup_child_pid=$!
    cleanup_poll_limit=$((cleanup_timeout * 10))
    while process_group_or_leader_is_active "$cleanup_child_pid" \
      && (( cleanup_poll_count < cleanup_poll_limit )); do
      if (( cleanup_child_reaped == 0 )) \
        && ! process_is_active "$cleanup_child_pid"; then
        wait "$cleanup_child_pid"
        cleanup_child_status=$?
        cleanup_child_reaped=1
      fi
      /bin/sleep 0.1
      cleanup_poll_count=$((cleanup_poll_count + 1))
    done
    if process_group_or_leader_is_active "$cleanup_child_pid"; then
      cleanup_child_timed_out=1
      log "ERROR: 独立清理进程组超过 ${cleanup_timeout}s，正在有界终止"
      if [[ "${BATTCYCLE_TEST_FAIL_CLEANUP_GROUP_TERMINATION:-0}" == "1" ]]; then
        cleanup_child_status=125
      elif process_group_is_active "$cleanup_child_pid"; then
        terminate_process_group "$cleanup_child_pid" || cleanup_child_status=125
      elif ! terminate_tree "$cleanup_child_pid"; then
        cleanup_child_status=125
      fi
    fi
    if (( cleanup_child_reaped == 0 )); then
      if process_group_or_leader_is_active "$cleanup_child_pid"; then
        cleanup_child_uncontained=1
      else
        wait "$cleanup_child_pid"
        cleanup_child_status=$?
        cleanup_child_reaped=1
      fi
    fi
    if (( cleanup_child_timed_out == 1 )); then
      (( cleanup_child_status == 125 )) || cleanup_child_status=124
    fi
  fi
  if (( cleanup_child_uncontained == 1 )); then
    log "ERROR: 独立清理进程组仍存活，拒绝并发 fallback；保留内核锁与运行记录供外部 Restore 收敛"
    exit 1
  fi
  if (( cleanup_child_status == 0 )); then
    exit "$original_status"
  fi

  log "ERROR: 独立清理程序返回非零或超时，启动一次有界幂等应急清理"
  BATTCYCLE_TEST_FAIL_CLEANUP_CHILD=0 \
    BATTCYCLE_TEST_CLEANUP_CHILD_BEHAVIOR="" \
    BATTCYCLE_TEST_FAIL_CLEANUP_GROUP_TERMINATION=0 \
    "$SYSTEM_PY" "$PROCESS_GROUP_EXEC" -- \
      /bin/zsh "$HERE/battery_cycle_stress.sh" \
      --battcycle-cleanup \
      "--battcycle-instance-token=$INSTANCE_TOKEN" \
      "--engine-pid=$$" &
  fallback_child_pid=$!
  while process_is_active "$fallback_child_pid" \
    && (( fallback_poll_count < fallback_poll_limit )); do
    /bin/sleep 0.1
    fallback_poll_count=$((fallback_poll_count + 1))
  done
  if ! process_is_active "$fallback_child_pid"; then
    wait "$fallback_child_pid"
    fallback_child_status=$?
    fallback_child_reaped=1
  else
    log "ERROR: 有界幂等应急清理超过 18s，正在终止"
    if process_group_is_active "$fallback_child_pid"; then
      terminate_process_group "$fallback_child_pid" || fallback_child_status=125
    elif ! terminate_tree "$fallback_child_pid"; then
      fallback_child_status=125
    fi
  fi
  if (( fallback_child_reaped == 0 )) && ! process_is_active "$fallback_child_pid"; then
    wait "$fallback_child_pid"
    fallback_child_status=$?
    fallback_child_reaped=1
  fi
  if (( fallback_child_reaped == 0 )) \
    || /bin/kill -0 -- "-$fallback_child_pid" 2>/dev/null; then
    log "ERROR: 有界幂等应急清理仍有进程存活，拒绝并发最终恢复"
    exit 1
  fi
  if (( fallback_child_status == 0 )); then
    exit "$original_status"
  fi

  log "ERROR: 有界幂等应急清理失败，执行原进程最终恢复"
  CLEANED_UP=0
  cleanup || cleanup_result=$?
  (( cleanup_result == 0 )) || original_status=1
  exit "$original_status"
}

validate_instance_token() {
  local supplied="${1:-}"
  if [[ ${#INSTANCE_TOKEN} -ne 32 || "$INSTANCE_TOKEN" == *[^0-9a-f]* ]]; then
    die "缺少有效的单实例 token"
  fi
  [[ "$supplied" == "--battcycle-instance-token=$INSTANCE_TOKEN" ]] || \
    die "单实例 token 与启动参数不匹配"
}

main() {
  if (( EUID == 0 )); then
    die "引擎必须以普通用户运行"
  fi
  (( $# == 1 )) || die "引擎只能由 BattCycle 单实例启动器运行"
  validate_instance_token "$1"

  require_executable "$SYSTEM_PY" "/usr/bin/python3"
  require_executable "$LOCK_TOOL" "engine_lock.py"
  require_executable "$BOUNDED_EXEC" "bounded_exec.py"
  require_executable "$PROCESS_GROUP_EXEC" "process_group_exec.py"
  require_executable "$PROCESS_GROUP_MARKER" "process_group_marker.py"
  require_engine_lock "$$"
  ENGINE_PGID="$(/bin/ps -p $$ -o pgid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
  [[ "$ENGINE_PGID" == "$$" ]] || die "引擎必须在独立进程组中运行"
  load_config

  trap on_exit EXIT
  trap 'exit 130' INT TERM HUP
  start_engine_marker

  require_executable "$BATT" "batt >= 0.8"
  require_executable "$MLX_PYTHON" "包含 mlx 的 Python"
  require_executable "$GPU_SCRIPT" "MLX 负载脚本"
  require_executable "$STRESS_NG" "stress-ng"
  require_executable "$CAFFEINATE" "caffeinate"
  require_guardian

  ln -sfn "$LOG" "$LATEST_LOG"
  rm -f "$STOP_FILE" "$STRESS_FAILURE_FILE"

  log "循环开始 upper=${UPPER_LIMIT}% lower=${LOWER_LIMIT}% gpu=${GPU_SIZE} cpu=${CPU_JOBS}"
  if (( STOP_AT_EPOCH > 0 )); then
    log "计划停止于 $(date -r "$STOP_AT_EPOCH" '+%Y-%m-%d %H:%M:%S %Z')"
  fi

  "$CAFFEINATE" -i -w $$ &
  CAFFEINATE_PID=$!

  read_snapshot
  if (( SNAPSHOT_PLUGGED != 1 || SNAPSHOT_ADAPTER != 1 )); then
    die "启动时必须已接入并启用电源适配器"
  fi
  if (( EXISTING_BATT_UPPER < UPPER_LIMIT )); then
    die "用户现有 batt 上限 ${EXISTING_BATT_UPPER}% 低于 BattCycle 上限 ${UPPER_LIMIT}%；请自行调整后重试"
  fi

  while true; do
    require_engine_lock "$$"
    require_engine_marker
    require_guardian
    check_stop_time || break
    check_stop_request || break
    read_snapshot
    require_plugged_snapshot
    log "phase=${PHASE} pct=${pct}% ${SNAPSHOT_SUMMARY}"

    if (( pct >= UPPER_LIMIT )); then
      if [[ "$PHASE" != "discharging" ]]; then
        PHASE="discharging"
        refresh_adapter_window || return 0
        log "达到上限，使用 ${LAST_ADAPTER_DURATION} 自动恢复窗口切断适配器"
        start_stress
      else
        refresh_adapter_window || return 0
      fi
    elif (( pct <= LOWER_LIMIT )); then
      if [[ "$PHASE" != "charging" ]]; then
        PHASE="charging"
        log "达到下限，停止负载并恢复适配器"
        stop_stress || die "无法确认放电负载已停止"
        batt_cmd adapter enable >> "$LOG" 2>&1 || die "无法恢复适配器"
        adapter_power_ready || die "适配器恢复后验证失败"
      fi
    elif [[ "$PHASE" == "discharging" ]]; then
      refresh_adapter_window || return 0
      start_stress
    elif [[ "$PHASE" == "init" ]]; then
      PHASE="charging"
      log "电量位于上下限之间，恢复适配器并充电"
      batt_cmd adapter enable >> "$LOG" 2>&1 || die "无法恢复适配器"
      adapter_power_ready || die "适配器恢复后验证失败"
    fi

    write_state
    local elapsed=0
    while (( elapsed < POLL_SECONDS )); do
      require_engine_lock "$$"
      require_engine_marker
      require_guardian
      check_stress_health
      check_stop_time || return 0
      check_stop_request || return 0
      sleep 1
      elapsed=$((elapsed + 1))
    done
  done
}

if [[ "$CLEANUP_MODE" == "1" ]]; then
  (( $# == 3 )) || die "独立清理参数数量无效"
  [[ "$1" == "--battcycle-cleanup" ]] || die "独立清理模式无效"
  validate_instance_token "$2"
  [[ "$3" == --engine-pid=<2-> ]] || die "独立清理 engine PID 无效"
  cleanup_owner_pid="${3#--engine-pid=}"
  require_executable "$SYSTEM_PY" "/usr/bin/python3"
  require_executable "$LOCK_TOOL" "engine_lock.py"
  if ! verify_engine_lock "$cleanup_owner_pid"; then
    # 锁路径失配时仍要优先恢复适配器，cleanup 不依赖该校验放行。
    log "ERROR: 独立清理检测到单实例锁失配，继续执行电源恢复"
  fi
  cleanup_group="$(/bin/ps -p $$ -o pgid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
  [[ "$cleanup_group" == "$$" ]] || \
    die "独立清理必须在自己的独立进程组中运行"
  marker_is_active "$MARKER_PID" "$cleanup_owner_pid" engine || \
    die "独立清理无法验证引擎进程组标记"

  case "${BATTCYCLE_TEST_CLEANUP_CHILD_BEHAVIOR:-}" in
    "")
      ;;
    nonzero)
      exit 91
      ;;
    timeout)
      /bin/sleep 30
      exit 92
      ;;
    *)
      die "未知的清理子进程测试模式"
      ;;
  esac

  set +e
  cleanup_result=0
  cleanup || cleanup_result=$?
  exit "$cleanup_result"
elif (( $# > 0 )) && [[ "$1" == "--battcycle-stress-worker" ]]; then
  stress_worker_main "$@"
elif [[ "${BATTCYCLE_TEST_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi

#!/bin/zsh
set -euo pipefail
setopt NO_BG_NICE
umask 077

# 所有外部依赖都指向临时 mock，测试绝不接触真实电源控制或压力负载。

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTROL="$ROOT/scripts/battcycle"
ENGINE="$ROOT/scripts/battery_cycle_stress.sh"
DETACHED="$ROOT/scripts/start-detached.sh"
TEMP_ROOT="$(mktemp -d /tmp/battcycle-script-tests.XXXXXX)"
MOCK_BIN="$TEMP_ROOT/bin"
MOCK_STATE_DIR="$TEMP_ROOT/mock-state"
MOCK_CALL_LOG="$TEMP_ROOT/calls.log"
CONFIG="$TEMP_ROOT/config.json"
SUPPORT="$TEMP_ROOT/support"
LOG_DIR="$TEMP_ROOT/logs"
guardian_pid=""
integration_group=""
integration_workload_group=""
wrong_token_group=""
stale_group=""
cleanup_child_group=""
stubborn_group=""

cleanup_test_files() {
  if [[ "$integration_group" == <1-> ]]; then
    /bin/kill -KILL -- "-$integration_group" 2>/dev/null || true
  fi
  if [[ "$integration_workload_group" == <1-> ]]; then
    /bin/kill -KILL -- "-$integration_workload_group" 2>/dev/null || true
  fi
  if [[ "$wrong_token_group" == <1-> ]]; then
    /bin/kill -KILL -- "-$wrong_token_group" 2>/dev/null || true
  fi
  if [[ "$stale_group" == <1-> ]]; then
    /bin/kill -KILL -- "-$stale_group" 2>/dev/null || true
  fi
  if [[ "$cleanup_child_group" == <1-> ]]; then
    /bin/kill -KILL -- "-$cleanup_child_group" 2>/dev/null || true
  fi
  if [[ "$stubborn_group" == <1-> ]]; then
    /bin/kill -KILL -- "-$stubborn_group" 2>/dev/null || true
  fi
  if [[ "$guardian_pid" == <1-> ]]; then
    kill "$guardian_pid" 2>/dev/null || true
    wait "$guardian_pid" 2>/dev/null || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup_test_files EXIT

mkdir -p "$MOCK_BIN" "$MOCK_STATE_DIR" "$SUPPORT" "$LOG_DIR"
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"

cat > "$MOCK_BIN/batt" <<'MOCK'
#!/bin/zsh
set -euo pipefail

print -r -- "$*" >> "$MOCK_CALL_LOG"

case "${1:-}" in
  version)
    version="${MOCK_VERSION:-0.8.1}"
    print -- "Client: v${version}"
    print -- "Daemon: v${version}"
    ;;
  status)
    [[ "${2:-}" == "--json" ]] || exit 2
    if [[ -f "$MOCK_STATE_DIR/hang-status" ]]; then
      print -r -- "HANG status" >> "$MOCK_CALL_LOG"
      /bin/sleep 30
    fi
    adapter="${MOCK_ADAPTER_ENABLED:-$(<"$MOCK_STATE_DIR/adapter")}"
    plugged="${MOCK_PLUGGED:-true}"
    upper="${MOCK_UPPER:-80}"
    allow_non_root="${MOCK_ALLOW_NON_ROOT:-true}"
    cat <<JSON
{
  "charging": {"useAdapter": ${adapter}, "pluggedIn": ${plugged}},
  "battery": {"currentChargePercent": 80, "state": "charging", "chargeRateWatts": 12.3},
  "configuration": {"allowNonRootAccess": ${allow_non_root}, "upperLimitPercent": ${upper}},
  "compatibility": {"adapterControl": true}
}
JSON
    ;;
  adapter)
    case "${2:-}" in
      disable)
        if [[ "${3:-}" == "--help" ]]; then
          print -- "--for duration"
          exit 0
        fi
        [[ "${3:-}" == --for=<1->s ]] || exit 22
        print -- "false" > "$MOCK_STATE_DIR/adapter"
        ;;
      enable)
        [[ "${MOCK_FAIL_ENABLE:-0}" != "1" ]] || exit 23
        print -- "true" > "$MOCK_STATE_DIR/adapter"
        ;;
      status)
        exit 0
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  limit|disable)
    print -r -- "FORBIDDEN $*" >> "$MOCK_CALL_LOG"
    exit 99
    ;;
  *)
    exit 2
    ;;
esac
MOCK

cat > "$MOCK_BIN/mlx-python" <<'MOCK'
#!/bin/zsh
set -euo pipefail
print -r -- "mlx-python $*" >> "$MOCK_CALL_LOG"
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  exit 0
fi
if [[ -f "$MOCK_STATE_DIR/mlx-fail" ]]; then
  exit 90
fi
trap 'exit 0' INT TERM HUP
while true; do /bin/sleep 1; done
MOCK

cat > "$MOCK_BIN/stress-ng" <<'MOCK'
#!/bin/zsh
set -euo pipefail
print -r -- "mock stress-ng $*" >> "$MOCK_CALL_LOG"
child_pid=""
if [[ -f "$MOCK_STATE_DIR/stress-child-ignore-term" ]]; then
  /bin/zsh -c 'trap "" TERM INT HUP; while true; do /bin/sleep 1; done' &
  child_pid=$!
fi
trap 'exit 0' INT TERM HUP
if [[ -n "$child_pid" ]]; then
  wait "$child_pid"
else
  while true; do /bin/sleep 1; done
fi
MOCK

cat > "$MOCK_BIN/caffeinate" <<'MOCK'
#!/bin/zsh
set -euo pipefail
print -r -- "mock caffeinate $*" >> "$MOCK_CALL_LOG"
trap 'exit 0' INT TERM HUP
while true; do /bin/sleep 1; done
MOCK

cat > "$MOCK_BIN/ps" <<'MOCK'
#!/bin/zsh
set -euo pipefail
print -r -- "${MOCK_PS_ROWS:-}"
MOCK

chmod 700 "$MOCK_BIN"/*

future_stop=$(( $(date '+%s') + 3600 ))
cat > "$CONFIG" <<JSON
{
  "upperLimit": 80,
  "lowerLimit": 30,
  "gpuSize": 2048,
  "cpuJobs": 4,
  "pollSeconds": 10,
  "stopAtEpoch": ${future_stop}
}
JSON

export BATT="$MOCK_BIN/batt"
export MLX_PYTHON="$MOCK_BIN/mlx-python"
export STRESS_NG="$MOCK_BIN/stress-ng"
export CAFFEINATE="$MOCK_BIN/caffeinate"
export BATTCYCLE_CONFIG="$CONFIG"
export BATTCYCLE_SUPPORT="$SUPPORT"
export BATTCYCLE_LOG_DIR="$LOG_DIR"
export MOCK_CALL_LOG MOCK_STATE_DIR

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  /usr/bin/grep -F -- "$text" "$file" >/dev/null || fail "未找到: $text"
}

assert_no_charge_limit_mutation() {
  if /usr/bin/grep -Eq '^(limit|disable)( |$)|^FORBIDDEN ' "$MOCK_CALL_LOG"; then
    fail "检测到 charge-limit 改写或真实负载调用"
  fi
}

write_test_config() {
  local config_path="$1"
  local stop_epoch="$2"
  cat > "$config_path" <<JSON
{
  "upperLimit": 80,
  "lowerLimit": 30,
  "gpuSize": 2048,
  "cpuJobs": 4,
  "pollSeconds": 5,
  "stopAtEpoch": ${stop_epoch}
}
JSON
}

start_test_guardian() {
  local support_dir="$1"
  mkdir -p "$support_dir"
  /bin/sleep 120 &
  guardian_pid=$!
  cat > "$support_dir/guardian.json" <<JSON
{
  "pid": ${guardian_pid},
  "updatedEpoch": $(date '+%s'),
  "thermalState": "nominal",
  "executablePath": "/bin/sleep"
}
JSON
}

group_is_alive() {
  local group_id="$1"
  /bin/kill -0 -- "-$group_id" 2>/dev/null || return 1
  /bin/ps -g "$group_id" -o pgid=,state= 2>/dev/null | /usr/bin/awk -v target="$group_id" '
    $1 == target && substr($2, 1, 1) != "Z" { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

group_has_marker() {
  local group_id="$1"
  local role="$2"
  /bin/ps -g "$group_id" -o pgid=,state=,command= 2>/dev/null | /usr/bin/awk \
    -v target="$group_id" -v marker="$ROOT/scripts/process_group_marker.py" \
    -v role="$role" '
      $1 == target && substr($2, 1, 1) != "Z" && index($0, marker) &&
        (index($0, "--role " role) || index($0, "--role=" role)) {
          found = 1
        }
      END { exit(found ? 0 : 1) }
    '
}

group_has_exact_marker() {
  local group_id="$1"
  local role="$2"
  local token="$3"
  local expected="$ROOT/scripts/process_group_marker.py --role $role --instance-token $token"
  /bin/ps -g "$group_id" -o pgid=,state=,command= 2>/dev/null | /usr/bin/awk \
    -v target="$group_id" -v expected="$expected" '
      $1 == target && substr($2, 1, 1) != "Z" {
        line = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", line)
        if (line == expected ||
            (length(line) > length(expected) &&
             substr(line, length(line) - length(expected), 1) == " " &&
             substr(line, length(line) - length(expected) + 1) == expected)) {
          found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    '
}

wait_for_pidfile() {
  local pidfile_path="$1"
  local attempt
  for attempt in {1..50}; do
    [[ -f "$pidfile_path" ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

wait_for_group_exit() {
  local group_id="$1"
  local attempt
  for attempt in {1..120}; do
    group_is_alive "$group_id" || return 0
    /bin/sleep 0.1
  done
  return 1
}

wait_for_pid_inactive() {
  local target_pid="$1"
  local attempt
  local process_state
  for attempt in {1..120}; do
    if ! /bin/kill -0 "$target_pid" 2>/dev/null; then
      return 0
    fi
    process_state="$(/bin/ps -p "$target_pid" -o state= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
    [[ "$process_state" == Z* ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

wait_for_log_text() {
  local log_path="$1"
  local expected="$2"
  local attempt
  for attempt in {1..120}; do
    if [[ -f "$log_path" ]] && /usr/bin/grep -F "$expected" "$log_path" >/dev/null; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

find_internal_group() {
  local mode="$1"
  local token="$2"
  local engine_pid="$3"
  local expected
  local process_table
  case "$mode" in
    cleanup)
      expected="$ROOT/scripts/battery_cycle_stress.sh --battcycle-cleanup --battcycle-instance-token=$token --engine-pid=$engine_pid"
      ;;
    stress)
      expected="$ROOT/scripts/battery_cycle_stress.sh --battcycle-stress-worker --battcycle-instance-token=$token --engine-pid=$engine_pid"
      ;;
    *)
      return 1
      ;;
  esac
  process_table="$(/bin/ps -axo pgid=,state=,command=)" || return 1
  print -r -- "$process_table" | /usr/bin/awk -v expected="$expected" '
    substr($2, 1, 1) != "Z" && index($0, expected) { groups[$1] = 1 }
    END {
      count = 0
      for (group in groups) {
        result = group
        count += 1
      }
      if (count == 1) {
        print result
        exit 0
      }
      exit 1
    }
  '
}

wait_for_stress_pgid() {
  local state_path="$1"
  local attempt
  local value=""
  for attempt in {1..80}; do
    if [[ -f "$state_path" ]]; then
      value="$(/usr/bin/python3 - "$state_path" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle).get("stressPgid", 0)
if type(value) is int and value > 1:
    print(value)
PY
)"
      if [[ "$value" == <2-> ]]; then
        print -- "$value"
        return 0
      fi
    fi
    /bin/sleep 0.1
  done
  return 1
}

wait_for_terminal_state() {
  local state_path="$1"
  local expected_phase="$2"
  local attempt
  for attempt in {1..120}; do
    if [[ -f "$state_path" ]] && /usr/bin/python3 - "$state_path" "$expected_phase" <<'PY' \
      >/dev/null 2>&1
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
expected = sys.argv[2]
if state.get("running") is not False or state.get("phase") != expected:
    raise SystemExit(1)
PY
    then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

# doctor 仅做读取检查。
"$CONTROL" doctor >/dev/null
assert_contains "$MOCK_CALL_LOG" "version"
assert_contains "$MOCK_CALL_LOG" "adapter disable --help"
assert_contains "$MOCK_CALL_LOG" "status --json"
assert_no_charge_limit_mutation

# 从含标准库同名文件的目录运行 doctor，也不得加载调用者当前目录。
SHADOW_CWD="$TEMP_ROOT/shadow-cwd"
SHADOW_SENTINEL="$TEMP_ROOT/shadow-imported"
mkdir -p "$SHADOW_CWD"
cat > "$SHADOW_CWD/re.py" <<'PY'
import os
with open(os.environ["BATTCYCLE_SHADOW_SENTINEL"], "a", encoding="utf-8") as handle:
    handle.write("re\n")
raise SystemExit(91)
PY
cat > "$SHADOW_CWD/json.py" <<'PY'
import os
with open(os.environ["BATTCYCLE_SHADOW_SENTINEL"], "a", encoding="utf-8") as handle:
    handle.write("json\n")
raise SystemExit(92)
PY
(
  cd "$SHADOW_CWD"
  BATTCYCLE_SHADOW_SENTINEL="$SHADOW_SENTINEL" "$CONTROL" doctor >/dev/null
)
[[ ! -e "$SHADOW_SENTINEL" ]] || fail "doctor 加载了调用者当前目录中的 Python 模块"
assert_contains "$MOCK_CALL_LOG" "mlx-python -I -c import mlx.core"

# 自选 token 且未继承内核锁的独立进程组不得直接运行 engine。
fake_token="0123456789abcdef0123456789abcdef"
: > "$MOCK_CALL_LOG"
direct_output=""
if direct_output="$(BATTCYCLE_INSTANCE_TOKEN="$fake_token" BATTCYCLE_LOCK_DIR_FD=8 \
  BATTCYCLE_LOCK_FD=9 \
  /usr/bin/python3 "$ROOT/scripts/process_group_exec.py" -- \
  /bin/zsh "$ENGINE" "--battcycle-instance-token=$fake_token" 2>&1)"; then
  fail "直接 process_group_exec 启动绕过了单实例锁验证"
fi
[[ "$direct_output" == *"单实例"* ]] || fail "直接 engine 拒绝原因不明确: $direct_output"
[[ ! -s "$MOCK_CALL_LOG" ]] || fail "单实例锁验证前已访问 batt"

# 内部 workload marker 扫描只接受当前 EUID，并且要求唯一精确候选。
foreign_uid=$(( EUID + 1 ))
internal_marker="/usr/bin/python3 $ROOT/scripts/process_group_marker.py --role workload --instance-token $fake_token"
internal_rows="$foreign_uid 6101 S $internal_marker
$EUID 6101 S $internal_marker"
BATTCYCLE_PS="$MOCK_BIN/ps" MOCK_PS_ROWS="$internal_rows" \
  BATTCYCLE_INSTANCE_TOKEN="$fake_token" BATTCYCLE_TEST_SOURCE_ONLY=1 \
  /bin/zsh -c '
    source "$1"
    process_group_has_workload_marker 6101
  ' _ "$ENGINE" >/dev/null || fail "当前 EUID workload marker 未通过认证"

if BATTCYCLE_PS="$MOCK_BIN/ps" MOCK_PS_ROWS="$foreign_uid 6101 S $internal_marker" \
  BATTCYCLE_INSTANCE_TOKEN="$fake_token" BATTCYCLE_TEST_SOURCE_ONLY=1 \
  /bin/zsh -c '
    source "$1"
    process_group_has_workload_marker 6101
  ' _ "$ENGINE" >/dev/null 2>&1; then
  fail "foreign EUID workload marker 被误认证"
fi

internal_rows="$EUID 6101 S $internal_marker
$EUID 6101 S $internal_marker"
if BATTCYCLE_PS="$MOCK_BIN/ps" MOCK_PS_ROWS="$internal_rows" \
  BATTCYCLE_INSTANCE_TOKEN="$fake_token" BATTCYCLE_TEST_SOURCE_ONLY=1 \
  /bin/zsh -c '
    source "$1"
    process_group_has_workload_marker 6101
  ' _ "$ENGINE" >/dev/null 2>&1; then
  fail "两个当前 EUID workload marker 未按歧义拒绝"
fi

# wrong-token marker 与无 marker 的陈旧 PGID 都不得被 stop_stress 发送整组信号。
wrong_token="fedcba9876543210fedcba9876543210"
BATTCYCLE_INSTANCE_TOKEN="$wrong_token" \
  /usr/bin/python3 "$ROOT/scripts/process_group_exec.py" -- \
    /usr/bin/python3 "$ROOT/scripts/process_group_marker.py" \
      --role workload --instance-token "$wrong_token" &
wrong_token_group=$!
for attempt in {1..30}; do
  group_has_exact_marker "$wrong_token_group" workload "$wrong_token" && break
  /bin/sleep 0.1
done
group_has_exact_marker "$wrong_token_group" workload "$wrong_token" || \
  fail "wrong-token workload marker 未启动"
if BATTCYCLE_INSTANCE_TOKEN="$fake_token" BATTCYCLE_TEST_SOURCE_ONLY=1 \
  /bin/zsh -c '
    source "$1"
    STRESS_PID="$2"
    stop_stress
  ' _ "$ENGINE" "$wrong_token_group" >/dev/null 2>&1; then
  fail "stop_stress 接受了 wrong-token workload marker"
fi
group_is_alive "$wrong_token_group" || fail "wrong-token PGID 被未授权地发送信号"
/bin/kill -HUP -- "-$wrong_token_group" 2>/dev/null || true
wait_for_group_exit "$wrong_token_group" || fail "wrong-token 测试进程组未退出"
wait "$wrong_token_group" 2>/dev/null || true
wrong_token_group=""

/usr/bin/python3 "$ROOT/scripts/process_group_exec.py" -- /bin/sleep 30 &
stale_group=$!
for attempt in {1..30}; do
  group_is_alive "$stale_group" && break
  /bin/sleep 0.1
done
group_is_alive "$stale_group" || fail "stale PGID 测试进程未启动"
if BATTCYCLE_INSTANCE_TOKEN="$fake_token" BATTCYCLE_TEST_SOURCE_ONLY=1 \
  /bin/zsh -c '
    source "$1"
    STRESS_PID="$2"
    stop_stress
  ' _ "$ENGINE" "$stale_group" >/dev/null 2>&1; then
  fail "stop_stress 接受了无 marker 的 stale PGID"
fi
group_is_alive "$stale_group" || fail "stale PGID 被未授权地发送信号"
/bin/kill -TERM -- "-$stale_group" 2>/dev/null || true
wait_for_group_exit "$stale_group" || fail "stale PGID 测试进程未退出"
wait "$stale_group" 2>/dev/null || true
stale_group=""

# workload marker 必须穿越整组 TERM，供强制 KILL 前再次精确认证。
BATTCYCLE_INSTANCE_TOKEN="$fake_token" \
  /usr/bin/python3 "$ROOT/scripts/process_group_exec.py" -- \
    /bin/zsh -c '
      trap "" TERM
      /usr/bin/python3 "$1" --role workload --instance-token "$2" &
      while true; do /bin/sleep 1; done
    ' _ "$ROOT/scripts/process_group_marker.py" "$fake_token" &
stubborn_group=$!
for attempt in {1..30}; do
  group_has_exact_marker "$stubborn_group" workload "$fake_token" && break
  /bin/sleep 0.1
done
group_has_exact_marker "$stubborn_group" workload "$fake_token" || \
  fail "stubborn workload marker 未启动"
if ! BATTCYCLE_INSTANCE_TOKEN="$fake_token" BATTCYCLE_TEST_SOURCE_ONLY=1 \
  /bin/zsh -c '
    source "$1"
    terminate_authenticated_workload_group "$2"
  ' _ "$ENGINE" "$stubborn_group" >/dev/null 2>&1; then
  fail "生产函数未能经 TERM 后重新认证并 KILL stubborn workload"
fi
wait_for_group_exit "$stubborn_group" || fail "重新认证后 KILL 未收敛 stubborn workload"
wait "$stubborn_group" 2>/dev/null || true
stubborn_group=""

# 旧版本、较低现有上限、未插电与已切断适配器都必须拒绝。
if MOCK_VERSION=0.7.9 "$CONTROL" doctor >/dev/null 2>&1; then
  fail "doctor 接受了 batt 0.7"
fi
if MOCK_UPPER=79 "$CONTROL" doctor >/dev/null 2>&1; then
  fail "doctor 接受了低于计划值的现有上限"
fi
if MOCK_PLUGGED=false "$CONTROL" doctor >/dev/null 2>&1; then
  fail "doctor 接受了未连接电源"
fi
if MOCK_ADAPTER_ENABLED=false "$CONTROL" doctor >/dev/null 2>&1; then
  fail "doctor 接受了已切断的适配器"
fi

# detached 的前置检查失败时不可 fork 引擎。
if MOCK_VERSION=0.7.9 "$DETACHED" "$CONFIG" "$SUPPORT" "$LOG_DIR" >/dev/null 2>&1; then
  fail "start-detached 在 doctor 失败时仍返回成功"
fi

# restore 成功时必须 enable 后通过 JSON 状态验证。
: > "$MOCK_CALL_LOG"
print -- "false" > "$MOCK_STATE_DIR/adapter"
"$CONTROL" restore >/dev/null
assert_contains "$MOCK_CALL_LOG" "adapter enable"
assert_contains "$MOCK_CALL_LOG" "status --json"
assert_no_charge_limit_mutation

# 物理电源断开时，restore 必须拒绝宣称恢复完成。
if MOCK_PLUGGED=false "$CONTROL" restore >/dev/null 2>&1; then
  fail "restore 在物理电源断开时仍报告成功"
fi

# restore 命令失败必须向调用方返回非零。
print -- "false" > "$MOCK_STATE_DIR/adapter"
if MOCK_FAIL_ENABLE=1 "$CONTROL" restore >/dev/null 2>&1; then
  fail "restore 屏蔽了 adapter enable 失败"
fi

# 直接加载函数，验证 --for 为正数、最多 600 秒且不越过总截止时间。
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"
BATTCYCLE_TEST_SOURCE_ONLY=1 /bin/zsh -c '
  source "$1"
  require_engine_lock() { return 0; }
  load_config
  STOP_AT_EPOCH=$(( $(date "+%s") + 347 ))
  disable_adapter_safely
  cleanup
' _ "$ENGINE" >/dev/null

disable_line="$(/usr/bin/grep -E '^adapter disable --for=[0-9]+s$' "$MOCK_CALL_LOG" | tail -1)"
[[ -n "$disable_line" ]] || fail "未调用带 --for 的适配器切断"
duration="${disable_line##*=}"
duration="${duration%s}"
(( duration > 0 )) || fail "--for 必须为正数"
(( duration <= 347 )) || fail "--for 越过总截止时间"
(( duration <= 600 )) || fail "--for 超过 600 秒"
assert_contains "$MOCK_CALL_LOG" "adapter enable"
assert_no_charge_limit_mutation

# App 心跳必须来自仍存活的同一可执行文件，且热状态只能是 nominal / fair。
GUARDIAN_SUPPORT="$TEMP_ROOT/guardian-support"
GUARDIAN_LOGS="$TEMP_ROOT/guardian-logs"
mkdir -p "$GUARDIAN_SUPPORT" "$GUARDIAN_LOGS"
/bin/sleep 30 &
guardian_pid=$!
guardian_path="/bin/sleep"
guardian_now="$(date '+%s')"
cat > "$GUARDIAN_SUPPORT/guardian.json" <<JSON
{
  "pid": ${guardian_pid},
  "updatedEpoch": ${guardian_now},
  "thermalState": "nominal",
  "executablePath": "${guardian_path}"
}
JSON

BATTCYCLE_SUPPORT="$GUARDIAN_SUPPORT" BATTCYCLE_LOG_DIR="$GUARDIAN_LOGS" \
  BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="$guardian_path" \
  BATTCYCLE_TEST_SOURCE_ONLY=1 /bin/zsh -c '
    source "$1"
    check_guardian
  ' _ "$ENGINE" >/dev/null || fail "有效 App 心跳未通过验证"

/usr/bin/python3 - "$GUARDIAN_SUPPORT/guardian.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["thermalState"] = "serious"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY

if BATTCYCLE_SUPPORT="$GUARDIAN_SUPPORT" BATTCYCLE_LOG_DIR="$GUARDIAN_LOGS" \
  BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="$guardian_path" \
  BATTCYCLE_TEST_SOURCE_ONLY=1 /bin/zsh -c '
    source "$1"
    check_guardian
  ' _ "$ENGINE" >/dev/null 2>&1; then
  fail "严重热状态仍通过安全守护"
fi
kill "$guardian_pid" 2>/dev/null || true
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=""

# 每次运行快照都必须对物理拔线 fail closed。
if MOCK_PLUGGED=false BATTCYCLE_TEST_SOURCE_ONLY=1 /bin/zsh -c '
  source "$1"
  load_config
  read_snapshot
  require_plugged_snapshot
' _ "$ENGINE" >/dev/null 2>&1; then
  fail "运行中拔线未触发 fail closed"
fi

# run.lock pathname 被换位后，正常 Start 必须识别旧 marker，不得覆写 PID 或短暂双启。
SPLIT_SUPPORT="$TEMP_ROOT/split-support"
SPLIT_LOGS="$TEMP_ROOT/split-logs"
SPLIT_CONFIG="$TEMP_ROOT/split-config.json"
mkdir -p "$SPLIT_SUPPORT" "$SPLIT_LOGS"
write_test_config "$SPLIT_CONFIG" $(( $(date '+%s') + 30 ))
start_test_guardian "$SPLIT_SUPPORT"
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"
BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
  "$DETACHED" "$SPLIT_CONFIG" "$SPLIT_SUPPORT" "$SPLIT_LOGS" >/dev/null
if ! wait_for_pidfile "$SPLIT_SUPPORT/run.pid"; then
  /bin/cat "$SPLIT_LOGS/engine.out" >&2 || true
  fail "pathname split 用例未发布 engine PID"
fi
integration_group="$(<"$SPLIT_SUPPORT/run.pid")"
for attempt in {1..30}; do
  group_has_marker "$integration_group" engine && break
  /bin/sleep 0.1
done
group_has_marker "$integration_group" engine || fail "pathname split 用例缺少 engine marker"
if ! integration_workload_group="$(wait_for_stress_pgid "$SPLIT_SUPPORT/state.json")"; then
  /bin/cat "$SPLIT_LOGS/engine.out" >&2 || true
  /bin/cat "$SPLIT_SUPPORT/state.json" >&2 || true
  fail "pathname split 用例未发布 workload PGID"
fi
/bin/kill -STOP "$integration_group"
split_original_pid="$(<"$SPLIT_SUPPORT/run.pid")"
/bin/mv "$SPLIT_SUPPORT/run.lock" "$SPLIT_SUPPORT/run.lock.displaced"
split_start_status=0
split_start_output="$(MOCK_ADAPTER_ENABLED=true BATTCYCLE_CONFIG="$SPLIT_CONFIG" \
  BATTCYCLE_SUPPORT="$SPLIT_SUPPORT" BATTCYCLE_LOG_DIR="$SPLIT_LOGS" \
  BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
  "$CONTROL" start 2>&1)" || split_start_status=$?
(( split_start_status == 0 )) || \
  fail "pathname split 后第二次 Start 未被 marker 稳定阻断: $split_start_output"
[[ "$split_start_output" == *"engine: already running pid=$integration_group"* ]] || \
  fail "pathname split 后 Start 未识别精确旧 marker: $split_start_output"
[[ "$(<"$SPLIT_SUPPORT/run.pid")" == "$split_original_pid" ]] || \
  fail "pathname split 后第二次 Start 覆写了旧 PID"
group_has_marker "$integration_group" engine || fail "pathname split 期间旧 engine marker 丢失"
/bin/kill -CONT "$integration_group"
wait_for_group_exit "$integration_group" || fail "pathname split 后 engine 未 fail closed"
wait_for_group_exit "$integration_workload_group" || \
  fail "pathname split 后 workload 未随 cleanup 收敛"
integration_group=""
integration_workload_group=""
assert_contains "$MOCK_CALL_LOG" "adapter enable"
[[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || \
  fail "pathname split 锁失配阻断了 cleanup 的 adapter enable"
/bin/kill "$guardian_pid" 2>/dev/null || true
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=""

# 完整 detached 生命周期：放电、deadline、负载停止、适配器恢复和 idle 终态。
INTEGRATION_SUPPORT="$TEMP_ROOT/integration-support"
INTEGRATION_LOGS="$TEMP_ROOT/integration-logs"
INTEGRATION_CONFIG="$TEMP_ROOT/integration-config.json"
mkdir -p "$INTEGRATION_SUPPORT" "$INTEGRATION_LOGS"
write_test_config "$INTEGRATION_CONFIG" $(( $(date '+%s') + 4 ))
start_test_guardian "$INTEGRATION_SUPPORT"
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"
BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
  "$DETACHED" "$INTEGRATION_CONFIG" "$INTEGRATION_SUPPORT" "$INTEGRATION_LOGS" >/dev/null
wait_for_pidfile "$INTEGRATION_SUPPORT/run.pid" || fail "detached 未发布 engine PID"
integration_group="$(<"$INTEGRATION_SUPPORT/run.pid")"
for attempt in {1..30}; do
  group_has_marker "$integration_group" engine && break
  /bin/sleep 0.1
done
group_has_marker "$integration_group" engine || fail "engine PGID 缺少存活身份标记"
integration_workload_group="$(wait_for_stress_pgid "$INTEGRATION_SUPPORT/state.json")" || \
  fail "detached 未发布 stressPgid"
[[ "$integration_workload_group" != "$integration_group" ]] || \
  fail "放电负载未使用独立 PGID"
group_has_marker "$integration_workload_group" workload || \
  fail "workload PGID 缺少存活身份标记"
wait_for_group_exit "$integration_group" || fail "deadline 后 engine 进程组仍存活"
wait_for_group_exit "$integration_workload_group" || fail "deadline 后 workload 进程组仍存活"
integration_group=""
integration_workload_group=""
assert_contains "$MOCK_CALL_LOG" "adapter disable --for="
assert_contains "$MOCK_CALL_LOG" "adapter enable"
[[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || fail "deadline cleanup 未恢复适配器"
/usr/bin/python3 - "$INTEGRATION_SUPPORT/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["phase"] == "idle", state
assert state["running"] is False, state
assert state["error"] is None, state
assert state["stressPgid"] == 0, state
PY
/bin/kill "$guardian_pid" 2>/dev/null || true
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=""

# MLX 快速失败必须 fail closed，且不可形成高频重启循环。
MLX_SUPPORT="$TEMP_ROOT/mlx-failure-support"
MLX_LOGS="$TEMP_ROOT/mlx-failure-logs"
MLX_CONFIG="$TEMP_ROOT/mlx-failure-config.json"
mkdir -p "$MLX_SUPPORT" "$MLX_LOGS"
write_test_config "$MLX_CONFIG" $(( $(date '+%s') + 15 ))
start_test_guardian "$MLX_SUPPORT"
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"
: > "$MOCK_STATE_DIR/mlx-fail"
BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
  "$DETACHED" "$MLX_CONFIG" "$MLX_SUPPORT" "$MLX_LOGS" >/dev/null
wait_for_pidfile "$MLX_SUPPORT/run.pid" || fail "MLX 失败用例未发布 engine PID"
integration_group="$(<"$MLX_SUPPORT/run.pid")"
if ! wait_for_group_exit "$integration_group"; then
  /bin/cat "$MLX_LOGS/engine.out" >&2 || true
  /bin/ps -axo pid=,ppid=,pgid=,state=,command= | \
    /usr/bin/awk -v target="$integration_group" '$3 == target {print}' >&2
  fail "MLX 失败后 engine 进程组仍存活"
fi
integration_group=""
if ! wait_for_terminal_state "$MLX_SUPPORT/state.json" failed; then
  /bin/cat "$MLX_LOGS/engine.out" >&2 || true
  fail "MLX 失败后未在有界时间内发布 failed 终态"
fi
mlx_runs="$(/usr/bin/grep -c '^mlx-python .*--size' "$MOCK_CALL_LOG" || true)"
(( mlx_runs == 1 )) || fail "MLX 失败后发生重复重启: $mlx_runs"
[[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || fail "MLX 失败 cleanup 未恢复适配器"
if ! /usr/bin/python3 - "$MLX_SUPPORT/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["phase"] == "failed", state
assert state["running"] is False, state
assert "放电负载失败" in state["error"], state
assert state["stressPgid"] == 0, state
PY
then
  /bin/cat "$MLX_LOGS/engine.out" >&2 || true
  fail "MLX 失败后未发布 failed 终态"
fi
rm -f "$MOCK_STATE_DIR/mlx-fail"
/bin/kill "$guardian_pid" 2>/dev/null || true
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=""

# 独立清理子进程无法启动时，原引擎必须执行有界应急清理。
FALLBACK_SUPPORT="$TEMP_ROOT/fallback-support"
FALLBACK_LOGS="$TEMP_ROOT/fallback-logs"
FALLBACK_CONFIG="$TEMP_ROOT/fallback-config.json"
mkdir -p "$FALLBACK_SUPPORT" "$FALLBACK_LOGS"
write_test_config "$FALLBACK_CONFIG" $(( $(date '+%s') + 4 ))
start_test_guardian "$FALLBACK_SUPPORT"
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"
BATTCYCLE_TEST_FAIL_CLEANUP_CHILD=1 \
  BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
  "$DETACHED" "$FALLBACK_CONFIG" "$FALLBACK_SUPPORT" "$FALLBACK_LOGS" >/dev/null
wait_for_pidfile "$FALLBACK_SUPPORT/run.pid" || fail "应急清理用例未发布 engine PID"
integration_group="$(<"$FALLBACK_SUPPORT/run.pid")"
wait_for_group_exit "$integration_group" || fail "应急清理后 engine 进程组仍存活"
integration_group=""
assert_contains "$MOCK_CALL_LOG" "adapter enable"
assert_contains "$FALLBACK_LOGS/engine.out" "启动一次有界幂等应急清理"
[[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || fail "应急清理未恢复适配器"
/usr/bin/python3 - "$FALLBACK_SUPPORT/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["phase"] == "idle", state
assert state["running"] is False, state
assert state["error"] is None, state
assert state["stressPgid"] == 0, state
PY
/bin/kill "$guardian_pid" 2>/dev/null || true
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=""

# cleanup 子进程显式非零与 bounded_exec 超时都必须触发幂等 fallback。
for cleanup_behavior in nonzero timeout; do
  CLEANUP_CASE_SUPPORT="$TEMP_ROOT/cleanup-${cleanup_behavior}-support"
  CLEANUP_CASE_LOGS="$TEMP_ROOT/cleanup-${cleanup_behavior}-logs"
  CLEANUP_CASE_CONFIG="$TEMP_ROOT/cleanup-${cleanup_behavior}-config.json"
  mkdir -p "$CLEANUP_CASE_SUPPORT" "$CLEANUP_CASE_LOGS"
  write_test_config "$CLEANUP_CASE_CONFIG" $(( $(date '+%s') + 4 ))
  start_test_guardian "$CLEANUP_CASE_SUPPORT"
  : > "$MOCK_CALL_LOG"
  print -- "true" > "$MOCK_STATE_DIR/adapter"
  BATTCYCLE_TEST_CLEANUP_CHILD_BEHAVIOR="$cleanup_behavior" \
    BATTCYCLE_TEST_CLEANUP_TIMEOUT_SECONDS=1 \
    BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
    "$DETACHED" "$CLEANUP_CASE_CONFIG" "$CLEANUP_CASE_SUPPORT" \
      "$CLEANUP_CASE_LOGS" >/dev/null
  wait_for_pidfile "$CLEANUP_CASE_SUPPORT/run.pid" || \
    fail "${cleanup_behavior} cleanup 用例未发布 engine PID"
  integration_group="$(<"$CLEANUP_CASE_SUPPORT/run.pid")"
  wait_for_group_exit "$integration_group" || \
    fail "${cleanup_behavior} cleanup fallback 后 engine 进程组仍存活"
  integration_group=""
  assert_contains "$CLEANUP_CASE_LOGS/engine.out" "启动一次有界幂等应急清理"
  [[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || \
    fail "${cleanup_behavior} cleanup fallback 未恢复适配器"
  /usr/bin/python3 - "$CLEANUP_CASE_SUPPORT/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["phase"] == "idle", state
assert state["running"] is False, state
assert state["error"] is None, state
assert state["stressPgid"] == 0, state
PY
  /bin/kill "$guardian_pid" 2>/dev/null || true
  wait "$guardian_pid" 2>/dev/null || true
  guardian_pid=""
done

# 运行中 Restore 会在 stop.request 被引擎观察后发送 TERM。
# cleanup supervisor 必须继续完成非零与超时子清理的有界收敛。
for cleanup_behavior in nonzero timeout; do
  ACTIVE_SUPPORT="$TEMP_ROOT/active-${cleanup_behavior}-support"
  ACTIVE_LOGS="$TEMP_ROOT/active-${cleanup_behavior}-logs"
  ACTIVE_CONFIG="$TEMP_ROOT/active-${cleanup_behavior}-config.json"
  mkdir -p "$ACTIVE_SUPPORT" "$ACTIVE_LOGS"
  write_test_config "$ACTIVE_CONFIG" $(( $(date '+%s') + 30 ))
  start_test_guardian "$ACTIVE_SUPPORT"
  : > "$MOCK_CALL_LOG"
  print -- "true" > "$MOCK_STATE_DIR/adapter"
  BATTCYCLE_TEST_CLEANUP_CHILD_BEHAVIOR="$cleanup_behavior" \
    BATTCYCLE_TEST_CLEANUP_TIMEOUT_SECONDS=1 \
    BATTCYCLE_STOP_GRACE_SECONDS=30 \
    BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
    "$DETACHED" "$ACTIVE_CONFIG" "$ACTIVE_SUPPORT" "$ACTIVE_LOGS" >/dev/null
  wait_for_pidfile "$ACTIVE_SUPPORT/run.pid" || \
    fail "active ${cleanup_behavior} 用例未发布 engine PID"
  integration_group="$(<"$ACTIVE_SUPPORT/run.pid")"
  integration_workload_group="$(wait_for_stress_pgid "$ACTIVE_SUPPORT/state.json")" || \
    fail "active ${cleanup_behavior} 用例未发布 stressPgid"
  active_restore_status=0
  active_restore_output="$(BATTCYCLE_STOP_GRACE_SECONDS=30 \
    BATTCYCLE_CONFIG="$ACTIVE_CONFIG" BATTCYCLE_SUPPORT="$ACTIVE_SUPPORT" \
    BATTCYCLE_LOG_DIR="$ACTIVE_LOGS" "$CONTROL" restore 2>&1)" || \
    active_restore_status=$?
  if (( active_restore_status != 0 )); then
    /bin/cat "$ACTIVE_LOGS/engine.out" >&2 || true
    for active_log in "$ACTIVE_LOGS"/battcycle_*.log(N); do
      /bin/cat "$active_log" >&2 || true
    done
    /bin/cat "$ACTIVE_SUPPORT/state.json" >&2 || true
    /bin/ps -axo pid=,ppid=,pgid=,state=,command= | /usr/bin/awk \
      -v engine="$integration_group" -v workload="$integration_workload_group" \
      '$3 == engine || $3 == workload {print}' >&2
    fail "active ${cleanup_behavior} restore 失败 ${active_restore_status}: ${active_restore_output}"
  fi
  [[ "$active_restore_output" == *"engine: stopped"* ]] || \
    fail "active ${cleanup_behavior} restore 未报告正常收敛: ${active_restore_output}"
  wait_for_group_exit "$integration_group" || \
    fail "active ${cleanup_behavior} restore 后 engine PGID 仍存活"
  wait_for_group_exit "$integration_workload_group" || \
    fail "active ${cleanup_behavior} restore 后 workload PGID 仍存活"
  integration_group=""
  integration_workload_group=""
  if ! wait_for_terminal_state "$ACTIVE_SUPPORT/state.json" idle; then
    /bin/cat "$ACTIVE_LOGS/engine.out" >&2 || true
    /bin/cat "$ACTIVE_SUPPORT/state.json" >&2 || true
    fail "active ${cleanup_behavior} restore 未发布 idle 终态"
  fi
  assert_contains "$ACTIVE_LOGS/engine.out" "启动一次有界幂等应急清理"
  if /usr/bin/grep -F "引擎异常退出" "$ACTIVE_LOGS/engine.out" >/dev/null; then
    fail "active ${cleanup_behavior} 将安全 stop.request 误报为引擎异常"
  fi
  [[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || \
    fail "active ${cleanup_behavior} restore 未恢复适配器"
  /bin/kill "$guardian_pid" 2>/dev/null || true
  wait "$guardian_pid" 2>/dev/null || true
  guardian_pid=""
done

# pre-marker barrier 期间 engine leader 崩溃时，workload 必须在任何 CPU/GPU 启动前退出。
PREMARKER_SUPPORT="$TEMP_ROOT/premarker-support"
PREMARKER_LOGS="$TEMP_ROOT/premarker-logs"
PREMARKER_CONFIG="$TEMP_ROOT/premarker-config.json"
PREMARKER_BARRIER="$PREMARKER_SUPPORT/test.pre-marker.barrier"
mkdir -p "$PREMARKER_SUPPORT" "$PREMARKER_LOGS"
write_test_config "$PREMARKER_CONFIG" $(( $(date '+%s') + 30 ))
start_test_guardian "$PREMARKER_SUPPORT"
: > "$PREMARKER_BARRIER"
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"
BATTCYCLE_TEST_PRE_MARKER_BARRIER_FILE="$PREMARKER_BARRIER" \
  BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
  "$DETACHED" "$PREMARKER_CONFIG" "$PREMARKER_SUPPORT" "$PREMARKER_LOGS" >/dev/null
wait_for_pidfile "$PREMARKER_SUPPORT/run.pid" || fail "pre-marker 用例未发布 engine PID"
integration_group="$(<"$PREMARKER_SUPPORT/run.pid")"
wait_for_log_text "$PREMARKER_LOGS/engine.out" "TEST: workload 已到达 pre-marker barrier" || \
  fail "workload 未到达 pre-marker barrier"
premarker_record="$(/usr/bin/python3 "$ROOT/scripts/engine_lock.py" owner \
  --lock "$PREMARKER_SUPPORT/run.lock" --with-token)" || fail "pre-marker 锁记录不可读"
read -r premarker_owner premarker_token <<< "$premarker_record"
[[ "$premarker_owner" == "$integration_group" ]] || fail "pre-marker 锁 owner 不匹配"
integration_workload_group="$(find_internal_group stress "$premarker_token" "$premarker_owner")" || \
  fail "pre-marker workload PGID 不可见"
if group_has_marker "$integration_workload_group" workload; then
  fail "pre-marker barrier 前已发布 workload marker"
fi
/bin/kill -KILL "$integration_group"
wait_for_pid_inactive "$integration_group" || fail "pre-marker engine leader 未退出"
wait_for_group_exit "$integration_workload_group" || \
  fail "pre-marker leader 崩溃后 workload 未 fail closed"
integration_workload_group=""
rm -f "$PREMARKER_BARRIER"
premarker_restore_status=0
premarker_restore_output="$(BATTCYCLE_STOP_GRACE_SECONDS=3 \
  BATTCYCLE_CONFIG="$PREMARKER_CONFIG" BATTCYCLE_SUPPORT="$PREMARKER_SUPPORT" \
  BATTCYCLE_LOG_DIR="$PREMARKER_LOGS" "$CONTROL" restore 2>&1)" || \
  premarker_restore_status=$?
(( premarker_restore_status == 0 || premarker_restore_status == 2 )) || \
  fail "pre-marker restore 失败 ${premarker_restore_status}: ${premarker_restore_output}"
wait_for_group_exit "$integration_group" || fail "pre-marker restore 后 engine PGID 仍存活"
integration_group=""
if /usr/bin/grep -Eq '^mock stress-ng |^mlx-python .*--size' "$MOCK_CALL_LOG"; then
  fail "pre-marker leader 崩溃后仍启动了 CPU/GPU 负载"
fi
[[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || fail "pre-marker restore 未恢复适配器"
/bin/kill "$guardian_pid" 2>/dev/null || true
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=""

# cleanup 整组终止失败时，engine parent 不得无界 wait 或并发 fallback。
TERMFAIL_SUPPORT="$TEMP_ROOT/termfail-support"
TERMFAIL_LOGS="$TEMP_ROOT/termfail-logs"
TERMFAIL_CONFIG="$TEMP_ROOT/termfail-config.json"
mkdir -p "$TERMFAIL_SUPPORT" "$TERMFAIL_LOGS"
write_test_config "$TERMFAIL_CONFIG" $(( $(date '+%s') + 4 ))
start_test_guardian "$TERMFAIL_SUPPORT"
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"
BATTCYCLE_TEST_CLEANUP_CHILD_BEHAVIOR=timeout \
  BATTCYCLE_TEST_CLEANUP_TIMEOUT_SECONDS=1 \
  BATTCYCLE_TEST_FAIL_CLEANUP_GROUP_TERMINATION=1 \
  BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
  "$DETACHED" "$TERMFAIL_CONFIG" "$TERMFAIL_SUPPORT" "$TERMFAIL_LOGS" >/dev/null
wait_for_pidfile "$TERMFAIL_SUPPORT/run.pid" || fail "terminate-failure 用例未发布 engine PID"
integration_group="$(<"$TERMFAIL_SUPPORT/run.pid")"
integration_workload_group="$(wait_for_stress_pgid "$TERMFAIL_SUPPORT/state.json")" || \
  fail "terminate-failure 用例未发布 stressPgid"
termfail_record="$(/usr/bin/python3 "$ROOT/scripts/engine_lock.py" owner \
  --lock "$TERMFAIL_SUPPORT/run.lock" --with-token)" || fail "terminate-failure 锁记录不可读"
read -r termfail_owner termfail_token <<< "$termfail_record"
wait_for_log_text "$TERMFAIL_LOGS/engine.out" "拒绝并发 fallback" || \
  fail "cleanup 终止失败后 engine parent 未有界退出"
wait_for_pid_inactive "$termfail_owner" || fail "cleanup 终止失败后 engine leader 无界阻塞"
cleanup_child_group="$(find_internal_group cleanup "$termfail_token" "$termfail_owner")" || \
  fail "terminate-failure cleanup PGID 不可见"
group_is_alive "$cleanup_child_group" || fail "terminate-failure cleanup PGID 未保留"
if /usr/bin/grep -F "启动一次有界幂等应急清理" \
  "$TERMFAIL_LOGS/engine.out" >/dev/null; then
  fail "cleanup 子进程仍存活时运行了并发 fallback"
fi
termfail_restore_status=0
termfail_restore_output="$(BATTCYCLE_STOP_GRACE_SECONDS=3 \
  BATTCYCLE_CONFIG="$TERMFAIL_CONFIG" BATTCYCLE_SUPPORT="$TERMFAIL_SUPPORT" \
  BATTCYCLE_LOG_DIR="$TERMFAIL_LOGS" "$CONTROL" restore 2>&1)" || \
  termfail_restore_status=$?
(( termfail_restore_status != 0 )) || fail "cleanup PGID 持锁时 controller 误报 restore 成功"
[[ "$termfail_restore_output" == *"内核锁仍被持有"* ]] || \
  fail "controller 未报告 cleanup PGID 的 busy lock: $termfail_restore_output"
wait_for_group_exit "$integration_group" || fail "terminate-failure restore 后 engine PGID 仍存活"
wait_for_group_exit "$integration_workload_group" || \
  fail "terminate-failure restore 后 workload PGID 仍存活"
integration_group=""
integration_workload_group=""
[[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || fail "terminate-failure restore 未恢复适配器"
/bin/kill -TERM -- "-$cleanup_child_group" 2>/dev/null || true
wait_for_group_exit "$cleanup_child_group" || fail "terminate-failure cleanup PGID 未退出"
cleanup_child_group=""
/usr/bin/python3 "$ROOT/scripts/engine_lock.py" clear-stale \
  --lock "$TERMFAIL_SUPPORT/run.lock" --pid-file "$TERMFAIL_SUPPORT/run.pid" >/dev/null || \
  fail "terminate-failure cleanup 退出后锁未释放"
/bin/kill "$guardian_pid" 2>/dev/null || true
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=""

# engine leader 被 SIGKILL 后，restore 必须从私有 PGID 记录清除残余负载组。
ORPHAN_SUPPORT="$TEMP_ROOT/orphan-support"
ORPHAN_LOGS="$TEMP_ROOT/orphan-logs"
ORPHAN_CONFIG="$TEMP_ROOT/orphan-config.json"
mkdir -p "$ORPHAN_SUPPORT" "$ORPHAN_LOGS"
write_test_config "$ORPHAN_CONFIG" $(( $(date '+%s') + 30 ))
start_test_guardian "$ORPHAN_SUPPORT"
: > "$MOCK_CALL_LOG"
print -- "true" > "$MOCK_STATE_DIR/adapter"
: > "$MOCK_STATE_DIR/stress-child-ignore-term"
BATTCYCLE_GUARDIAN_PID="$guardian_pid" BATTCYCLE_GUARDIAN_PATH="/bin/sleep" \
  "$DETACHED" "$ORPHAN_CONFIG" "$ORPHAN_SUPPORT" "$ORPHAN_LOGS" >/dev/null
wait_for_pidfile "$ORPHAN_SUPPORT/run.pid" || fail "orphan 用例未发布 engine PID"
integration_group="$(<"$ORPHAN_SUPPORT/run.pid")"
for attempt in {1..50}; do
  /usr/bin/grep -F "adapter disable --for=" "$MOCK_CALL_LOG" >/dev/null && break
  /bin/sleep 0.1
done
assert_contains "$MOCK_CALL_LOG" "adapter disable --for="
integration_workload_group="$(wait_for_stress_pgid "$ORPHAN_SUPPORT/state.json")" || \
  fail "orphan 用例未发布 stressPgid"
[[ "$integration_workload_group" != "$integration_group" ]] || \
  fail "orphan 放电负载未使用独立 PGID"
group_has_marker "$integration_group" engine || fail "orphan engine marker 未存活"
group_has_marker "$integration_workload_group" workload || fail "orphan workload marker 未存活"
/bin/sleep 0.5
/bin/kill -KILL "$integration_group"
/bin/sleep 0.2
group_is_alive "$integration_group" || fail "leader 崩溃后未形成预期残余负载组"
group_has_marker "$integration_group" engine || fail "leader 崩溃后 engine marker 未继续存活"
group_has_marker "$integration_workload_group" workload || fail "leader 崩溃后 workload marker 未继续存活"
restore_status=0
restore_output="$(BATTCYCLE_CONFIG="$ORPHAN_CONFIG" BATTCYCLE_SUPPORT="$ORPHAN_SUPPORT" \
  BATTCYCLE_LOG_DIR="$ORPHAN_LOGS" "$CONTROL" restore 2>&1)" || restore_status=$?
(( restore_status == 0 || restore_status == 2 )) || \
  fail "restore 返回异常状态 ${restore_status}: ${restore_output}"
if ! wait_for_group_exit "$integration_group"; then
  print -u2 -- "restore status=${restore_status} output=${restore_output}"
  /bin/ps -axo pid=,ppid=,pgid=,state=,command= | \
    /usr/bin/awk -v target="$integration_group" '$3 == target {print}' >&2
  fail "restore 未清除 leader-dead 进程组"
fi
if ! wait_for_group_exit "$integration_workload_group"; then
  print -u2 -- "restore status=${restore_status} output=${restore_output}"
  /bin/ps -axo pid=,ppid=,pgid=,state=,command= | \
    /usr/bin/awk -v target="$integration_workload_group" '$3 == target {print}' >&2
  fail "restore 未清除 leader-dead workload 进程组"
fi
integration_group=""
integration_workload_group=""
[[ "$(<"$MOCK_STATE_DIR/adapter")" == "true" ]] || fail "orphan 恢复未启用适配器"
[[ ! -e "$ORPHAN_SUPPORT/run.pid" ]] || fail "orphan 恢复未清理 PID 文件"
rm -f "$MOCK_STATE_DIR/stress-child-ignore-term"
/bin/kill "$guardian_pid" 2>/dev/null || true
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=""

# cleanup 恢复失败时必须写入 failed 终态和明确错误。
FAILED_SUPPORT="$TEMP_ROOT/failed-support"
FAILED_LOGS="$TEMP_ROOT/failed-logs"
mkdir -p "$FAILED_SUPPORT" "$FAILED_LOGS"
print -- "false" > "$MOCK_STATE_DIR/adapter"
if BATTCYCLE_SUPPORT="$FAILED_SUPPORT" BATTCYCLE_LOG_DIR="$FAILED_LOGS" \
  MOCK_FAIL_ENABLE=1 BATTCYCLE_TEST_SOURCE_ONLY=1 /bin/zsh -c '
    source "$1"
    load_config
    cleanup
  ' _ "$ENGINE" >/dev/null 2>&1; then
  fail "cleanup 恢复失败仍返回成功"
fi

/usr/bin/python3 - "$FAILED_SUPPORT/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["phase"] == "failed", state
assert state["running"] is False, state
assert state["error"] == "适配器恢复失败，请检查日志并手动恢复", state
PY

# 运行期 die 即使成功恢复适配器，也必须保留原始失败原因。
RUNTIME_SUPPORT="$TEMP_ROOT/runtime-support"
RUNTIME_LOGS="$TEMP_ROOT/runtime-logs"
mkdir -p "$RUNTIME_SUPPORT" "$RUNTIME_LOGS"
print -- "true" > "$MOCK_STATE_DIR/adapter"
if BATTCYCLE_SUPPORT="$RUNTIME_SUPPORT" BATTCYCLE_LOG_DIR="$RUNTIME_LOGS" \
  BATTCYCLE_TEST_SOURCE_ONLY=1 /bin/zsh -c '
    source "$1"
    load_config
    trap on_exit EXIT
    die "模拟运行错误"
  ' _ "$ENGINE" >/dev/null 2>&1; then
  fail "运行期 die 仍返回成功"
fi

/usr/bin/python3 - "$RUNTIME_SUPPORT/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["phase"] == "failed", state
assert state["running"] is False, state
assert state["error"] == "模拟运行错误", state
PY

# 源码层保证已移除全部特权路径与动态 shell 求值。
if rg -n '(^|[;&|[:space:]])(sudo|pmset|launchctl|eval)([;&|[:space:]]|$)' \
  "$ROOT/scripts/battcycle" "$ROOT/scripts/"*.sh >/dev/null; then
  fail "脚本仍包含禁用的特权命令"
fi
[[ ! -e "$ROOT/scripts/helper-loop.sh" ]] || fail "helper-loop.sh 仍存在"
[[ ! -e "$ROOT/scripts/install-helper.sh" ]] || fail "install-helper.sh 仍存在"

print -- "shell mocks: ok"

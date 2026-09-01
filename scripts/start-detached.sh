#!/bin/zsh
set -euo pipefail

# 以普通用户新建独立会话启动引擎，并在 exec 被接受后迅速返回。

if (( EUID == 0 )); then
  print -u2 -- "start-detached: 必须以普通用户运行"
  exit 1
fi

if (( $# != 3 )); then
  print -u2 -- "用法: start-detached.sh <config绝对路径> <support绝对目录> <logs绝对目录>"
  exit 2
fi

CONFIG_JSON="$1"
SUPPORT="$2"
LOG_DIR="$3"

for candidate_path in "$CONFIG_JSON" "$SUPPORT" "$LOG_DIR"; do
  if [[ "$candidate_path" != /* || "$candidate_path" == "/" || "$candidate_path" == *[[:cntrl:]]* ]]; then
    print -u2 -- "start-detached: 路径必须是安全的绝对路径: $candidate_path"
    exit 2
  fi
done

if [[ -e "$CONFIG_JSON" && ! -f "$CONFIG_JSON" ]]; then
  print -u2 -- "start-detached: 配置路径必须是普通文件"
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTROL="$HERE/battcycle"
ENGINE_LOG="$LOG_DIR/engine.out"
GUARDIAN_PID="${BATTCYCLE_GUARDIAN_PID:-}"
GUARDIAN_PATH="${BATTCYCLE_GUARDIAN_PATH:-}"

[[ -x "/usr/bin/python3" ]] || {
  print -u2 -- "start-detached: 缺少 /usr/bin/python3"
  exit 1
}
[[ -x "$CONTROL" ]] || {
  print -u2 -- "start-detached: 控制脚本不可执行: $CONTROL"
  exit 1
}
if [[ "$GUARDIAN_PID" != <1-> || "$GUARDIAN_PID" -le 1 ]]; then
  print -u2 -- "start-detached: 缺少有效的 App 安全守护 PID"
  exit 1
fi
if [[ "$GUARDIAN_PATH" != /* || "$GUARDIAN_PATH" == *[[:cntrl:]]* ]]; then
  print -u2 -- "start-detached: 缺少有效的 App 安全守护路径"
  exit 1
fi

umask 077
mkdir -p "$SUPPORT" "$LOG_DIR"
cd /

export BATTCYCLE_CONFIG="$CONFIG_JSON"
export BATTCYCLE_SUPPORT="$SUPPORT"
export BATTCYCLE_LOG_DIR="$LOG_DIR"
export BATTCYCLE_CONTROL="$CONTROL"
export BATTCYCLE_ENGINE_LOG="$ENGINE_LOG"
export BATTCYCLE_GUARDIAN_PID="$GUARDIAN_PID"
export BATTCYCLE_GUARDIAN_PATH="$GUARDIAN_PATH"

# 在 fork 前完成所有只读依赖检查，使调用方能收到明确失败状态。
"$CONTROL" doctor >/dev/null

exec /usr/bin/python3 -I - <<'PY'
import os
import sys

control = os.environ["BATTCYCLE_CONTROL"]
log_path = os.environ["BATTCYCLE_ENGINE_LOG"]

if os.geteuid() == 0:
    print("start-detached: 拒绝以 root 身份启动", file=sys.stderr)
    sys.exit(1)

read_fd, write_fd = os.pipe()

try:
    first_pid = os.fork()
except OSError as error:
    print("start-detached: 第一次 fork 失败: {}".format(error), file=sys.stderr)
    sys.exit(1)

if first_pid > 0:
    os.close(write_fd)
    message = b""
    while True:
        chunk = os.read(read_fd, 4096)
        if not chunk:
            break
        message += chunk
    os.close(read_fd)
    if message:
        print(message.decode("utf-8", "replace"), file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

os.close(read_fd)

try:
    os.setsid()
    os.chdir("/")
    os.umask(0o077)
    os.makedirs(os.path.dirname(log_path), mode=0o700, exist_ok=True)

    log = open(log_path, "a", buffering=1, encoding="utf-8")
    devnull = open("/dev/null", "rb")
    os.dup2(devnull.fileno(), 0)
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)
    print(
        "[detached] exec {} pid={} uid={}".format(
            control, os.getpid(), os.getuid()
        ),
        flush=True,
    )

    # Python 3 默认让管道描述符在 exec 时关闭；EOF 表示 exec 已被接受。
    os.execve("/bin/zsh", ["/bin/zsh", control, "start"], os.environ.copy())
except BaseException as error:
    try:
        os.write(write_fd, "start-detached: {}".format(error).encode("utf-8"))
    finally:
        os._exit(1)
PY

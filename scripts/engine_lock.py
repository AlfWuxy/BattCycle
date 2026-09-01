#!/usr/bin/env python3
"""用内核文件锁保证同一时间只有一个 BattCycle 引擎实例。"""

import argparse
import errno
import fcntl
import json
import os
import secrets
import stat
import sys
import time
from typing import Optional, Sequence


LOCK_BUSY_STATUS = 75
NO_ACTIVE_VALUE_STATUS = 3
TOKEN_PREFIX = "--battcycle-instance-token="
MAX_LOCK_BYTES = 4096
MAX_STATE_BYTES = 65536
LOCK_DIRECTORY_FD_ENV = "BATTCYCLE_LOCK_DIR_FD"


class LockError(RuntimeError):
    """锁文件或实例元数据不满足安全要求。"""


def absolute_path(value: str) -> str:
    if not os.path.isabs(value):
        raise argparse.ArgumentTypeError("路径必须使用绝对路径")
    return os.path.normpath(value)


def descriptor_number(value: str) -> int:
    try:
        descriptor = int(value, 10)
    except ValueError as error:
        raise argparse.ArgumentTypeError("文件描述符必须是整数") from error
    if descriptor < 3 or descriptor > 1_048_576:
        raise argparse.ArgumentTypeError("文件描述符超出允许范围")
    return descriptor


def positive_pid(value: str) -> int:
    try:
        pid = int(value, 10)
    except ValueError as error:
        raise argparse.ArgumentTypeError("PID 必须是整数") from error
    if pid <= 1:
        raise argparse.ArgumentTypeError("PID 必须大于 1")
    return pid


def valid_token(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 32
        and all(character in "0123456789abcdef" for character in value)
    )


def validate_regular_metadata(
    metadata: os.stat_result,
    *,
    maximum_size: int,
    exact_mode: Optional[int] = None,
    allow_empty: bool = False,
) -> None:
    if not stat.S_ISREG(metadata.st_mode):
        raise LockError("目标必须是普通文件")
    if metadata.st_uid != os.getuid():
        raise LockError("文件所有者与当前用户不一致")
    if exact_mode is not None and stat.S_IMODE(metadata.st_mode) != exact_mode:
        raise LockError("文件权限必须为 {:04o}".format(exact_mode))
    if metadata.st_size < 0 or metadata.st_size > maximum_size:
        raise LockError("文件大小超出允许范围")
    if not allow_empty and metadata.st_size == 0:
        raise LockError("文件内容为空")


def validate_lock_metadata(
    metadata: os.stat_result,
    *,
    allow_empty: bool = False,
) -> None:
    """校验锁文件的专用不变量。"""
    validate_regular_metadata(
        metadata,
        maximum_size=MAX_LOCK_BYTES,
        exact_mode=0o600,
        allow_empty=allow_empty,
    )
    if metadata.st_nlink != 1:
        raise LockError("锁文件链接数必须为 1")


def validate_lock_directory_metadata(metadata: os.stat_result) -> None:
    """校验用作稳定锁锚点的父目录。"""
    if not stat.S_ISDIR(metadata.st_mode):
        raise LockError("锁文件父路径必须是目录")
    if metadata.st_uid != os.geteuid():
        raise LockError("锁文件父目录所有者与当前用户不一致")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise LockError("锁文件父目录不得允许组或其他用户写入")


def read_descriptor_bytes(descriptor: int, maximum_size: int) -> bytes:
    metadata = os.fstat(descriptor)
    if metadata.st_size > maximum_size:
        raise LockError("文件大小超出允许范围")
    payload = os.pread(descriptor, maximum_size + 1, 0)
    if len(payload) > maximum_size:
        raise LockError("文件大小超出允许范围")
    return payload


def read_json_descriptor(descriptor: int, maximum_size: int) -> object:
    try:
        return json.loads(read_descriptor_bytes(descriptor, maximum_size).decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise LockError("JSON 内容无效") from error


def validate_lock_payload(payload: object) -> tuple[int, str]:
    if not isinstance(payload, dict):
        raise LockError("锁元数据结构无效")
    pid = payload.get("pid")
    token = payload.get("token")
    started = payload.get("startedEpoch")
    command = payload.get("command")
    if type(pid) is not int or pid <= 1:
        raise LockError("锁元数据 PID 无效")
    if not valid_token(token):
        raise LockError("锁元数据 token 无效")
    if type(started) is not int or started <= 0:
        raise LockError("锁元数据启动时间无效")
    if not isinstance(command, str) or not os.path.isabs(command):
        raise LockError("锁元数据命令无效")
    return pid, token


def open_existing_regular(path: str, maximum_size: int, exact_mode: Optional[int]) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        validate_regular_metadata(
            os.fstat(descriptor),
            maximum_size=maximum_size,
            exact_mode=exact_mode,
        )
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_existing_lock(path: str) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        validate_lock_metadata(os.fstat(descriptor))
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_lock_directory(path: str) -> int:
    parent = os.path.dirname(path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(parent, flags)
    try:
        validate_lock_directory_metadata(os.fstat(descriptor))
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_lock(path: str) -> int:
    flags = os.O_RDWR | os.O_CREAT
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    metadata = os.fstat(descriptor)
    try:
        os.fchmod(descriptor, 0o600)
        validate_lock_metadata(os.fstat(descriptor), allow_empty=True)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def acquire_nonblocking(descriptor: int) -> bool:
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError as error:
        if error.errno in (errno.EACCES, errno.EAGAIN):
            return False
        raise


def write_lock_metadata(descriptor: int, command: Sequence[str], token: str) -> None:
    payload = {
        "command": command[0],
        "pid": os.getpid(),
        "startedEpoch": int(time.time()),
        "token": token,
    }
    encoded = (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
    os.lseek(descriptor, 0, os.SEEK_SET)
    os.ftruncate(descriptor, 0)
    os.write(descriptor, encoded)
    os.fsync(descriptor)


def write_pid_file(path: str, pid: int) -> None:
    parent = os.path.dirname(path)
    temporary = os.path.join(parent, ".run.pid.{}.{}".format(pid, secrets.token_hex(4)))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        os.write(descriptor, (str(pid) + "\n").encode("ascii"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def remove_pid_if_owned(path: str, pid: int) -> None:
    try:
        with open(path, "r", encoding="ascii") as handle:
            value = handle.read(64).strip()
    except (FileNotFoundError, OSError, UnicodeError):
        return
    if value == str(pid):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def normalized_command(values: Sequence[str]) -> list[str]:
    command = list(values)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise LockError("缺少待执行命令")
    if not os.path.isabs(command[0]):
        raise LockError("可执行文件必须使用绝对路径")
    return command


def run_locked(args: argparse.Namespace) -> int:
    if os.geteuid() == 0:
        raise LockError("拒绝以 root 身份启动引擎")
    command = normalized_command(args.command)
    directory = open_lock_directory(args.lock)
    if not acquire_nonblocking(directory):
        os.close(directory)
        print("engine_lock: 已有运行实例", file=sys.stderr)
        return LOCK_BUSY_STATUS
    try:
        descriptor = open_lock(args.lock)
    except BaseException:
        os.close(directory)
        raise
    if not acquire_nonblocking(descriptor):
        os.close(descriptor)
        os.close(directory)
        print("engine_lock: 已有运行实例", file=sys.stderr)
        return LOCK_BUSY_STATUS

    token = secrets.token_hex(16)
    write_lock_metadata(descriptor, command, token)
    write_pid_file(args.pid_file, os.getpid())
    environment = os.environ.copy()
    environment["BATTCYCLE_INSTANCE_TOKEN"] = token
    environment["BATTCYCLE_ENGINE_PID"] = str(os.getpid())
    if args.append_token:
        command.append(TOKEN_PREFIX + token)
    os.set_inheritable(directory, True)
    os.set_inheritable(descriptor, True)
    environment[LOCK_DIRECTORY_FD_ENV] = str(directory)
    environment["BATTCYCLE_LOCK_FD"] = str(descriptor)
    try:
        os.execve(command[0], command, environment)
    except OSError as error:
        remove_pid_if_owned(args.pid_file, os.getpid())
        os.ftruncate(descriptor, 0)
        print("engine_lock: 无法启动引擎: {}".format(error), file=sys.stderr)
        return 126


def clear_stale(args: argparse.Namespace) -> int:
    directory = open_lock_directory(args.lock)
    if not acquire_nonblocking(directory):
        os.close(directory)
        return LOCK_BUSY_STATUS
    try:
        descriptor = open_lock(args.lock)
    except BaseException:
        os.close(directory)
        raise
    try:
        if not acquire_nonblocking(descriptor):
            return LOCK_BUSY_STATUS
        os.ftruncate(descriptor, 0)
        os.fsync(descriptor)
        try:
            os.unlink(args.pid_file)
        except FileNotFoundError:
            pass
        return 0
    finally:
        os.close(descriptor)
        os.close(directory)


def verify_held(args: argparse.Namespace) -> int:
    if not valid_token(args.token):
        raise LockError("实例 token 无效")
    if os.environ.get("BATTCYCLE_LOCK_FD") != str(args.fd):
        raise LockError("继承锁 FD 与环境记录不一致")
    if os.environ.get(LOCK_DIRECTORY_FD_ENV) != str(args.dir_fd):
        raise LockError("继承锁目录 FD 与环境记录不一致")
    if os.environ.get("BATTCYCLE_ENGINE_PID") != str(args.pid):
        raise LockError("引擎 PID 与环境记录不一致")
    if os.environ.get("BATTCYCLE_INSTANCE_TOKEN") != args.token:
        raise LockError("实例 token 与环境记录不一致")

    inherited_directory_metadata = os.fstat(args.dir_fd)
    validate_lock_directory_metadata(inherited_directory_metadata)
    directory_probe = open_lock_directory(args.lock)
    try:
        directory_probe_metadata = os.fstat(directory_probe)
        if (
            directory_probe_metadata.st_dev != inherited_directory_metadata.st_dev
            or directory_probe_metadata.st_ino != inherited_directory_metadata.st_ino
        ):
            raise LockError("继承锁目录 FD 与锁路径父目录不一致")
        if acquire_nonblocking(directory_probe):
            fcntl.flock(directory_probe, fcntl.LOCK_UN)
            raise LockError("锁目录当前未被继承 FD 持有")
        if not acquire_nonblocking(args.dir_fd):
            raise LockError("继承锁目录 FD 不属于当前锁持有者")
    finally:
        os.close(directory_probe)

    inherited_metadata = os.fstat(args.fd)
    validate_lock_metadata(inherited_metadata)
    probe = open_existing_lock(args.lock)
    try:
        probe_metadata = os.fstat(probe)
        if (
            probe_metadata.st_dev != inherited_metadata.st_dev
            or probe_metadata.st_ino != inherited_metadata.st_ino
        ):
            raise LockError("继承锁 FD 与锁路径不是同一文件")
        if acquire_nonblocking(probe):
            fcntl.flock(probe, fcntl.LOCK_UN)
            raise LockError("锁文件当前未被继承 FD 持有")
        if not acquire_nonblocking(args.fd):
            raise LockError("继承 FD 不属于当前锁持有者")
    finally:
        os.close(probe)

    payload = read_json_descriptor(args.fd, MAX_LOCK_BYTES)
    pid, token = validate_lock_payload(payload)
    if pid != args.pid or token != args.token:
        raise LockError("继承锁元数据与引擎身份不一致")
    return 0


def show_owner(args: argparse.Namespace) -> int:
    try:
        descriptor = open_existing_lock(args.lock)
    except (FileNotFoundError, LockError, OSError):
        return 1
    try:
        if acquire_nonblocking(descriptor):
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            return 1
        payload = read_json_descriptor(descriptor, MAX_LOCK_BYTES)
        pid, token = validate_lock_payload(payload)
    except (LockError, OSError, TypeError):
        return 1
    finally:
        os.close(descriptor)

    if args.with_token:
        print("{} {}".format(pid, token))
    else:
        print(pid)
    return 0


def write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise LockError("无法完整写入文件")
        offset += written


def secure_atomic_write(path: str, payload: bytes) -> None:
    parent = os.path.dirname(path)
    basename = os.path.basename(path)
    if not basename or basename in (".", ".."):
        raise LockError("目标文件名无效")
    directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory = os.open(parent, directory_flags)
    temporary = ".{}.{}.tmp".format(basename, secrets.token_hex(16))
    descriptor = -1
    try:
        directory_metadata = os.fstat(directory)
        if not stat.S_ISDIR(directory_metadata.st_mode):
            raise LockError("目标父路径必须是目录")
        if directory_metadata.st_uid != os.getuid():
            raise LockError("目标目录所有者与当前用户不一致")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o600, dir_fd=directory)
        write_all(descriptor, payload)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(
            temporary,
            basename,
            src_dir_fd=directory,
            dst_dir_fd=directory,
        )
        os.fsync(directory)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
        raise
    finally:
        os.close(directory)


def write_request(args: argparse.Namespace) -> int:
    encoded = args.value.encode("utf-8")
    if not encoded or len(encoded) > 128:
        raise LockError("停止请求内容长度无效")
    if any(character < 0x20 or character == 0x7F for character in encoded):
        raise LockError("停止请求包含控制字符")
    secure_atomic_write(args.path, encoded + b"\n")
    return 0


def read_state_pgid(args: argparse.Namespace) -> int:
    try:
        descriptor = open_existing_regular(args.path, MAX_STATE_BYTES, 0o600)
    except FileNotFoundError:
        return NO_ACTIVE_VALUE_STATUS
    try:
        payload = read_json_descriptor(descriptor, MAX_STATE_BYTES)
    finally:
        os.close(descriptor)
    if not isinstance(payload, dict):
        raise LockError("状态 JSON 结构无效")
    group_id = payload.get("stressPgid")
    if group_id is None or group_id == 0:
        return NO_ACTIVE_VALUE_STATUS
    if type(group_id) is not int or group_id <= 1:
        raise LockError("状态 stressPgid 无效")
    print(group_id)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="管理 BattCycle 单实例内核锁")
    subparsers = parser.add_subparsers(dest="action", required=True)

    run_parser = subparsers.add_parser("run", help="持锁并原位启动引擎")
    run_parser.add_argument("--lock", required=True, type=absolute_path)
    run_parser.add_argument("--pid-file", required=True, type=absolute_path)
    run_parser.add_argument("--append-token", action="store_true")
    run_parser.add_argument("command", nargs=argparse.REMAINDER)

    clear_parser = subparsers.add_parser("clear-stale", help="仅在锁空闲时清理旧记录")
    clear_parser.add_argument("--lock", required=True, type=absolute_path)
    clear_parser.add_argument("--pid-file", required=True, type=absolute_path)

    owner_parser = subparsers.add_parser("owner", help="读取经过校验的记录 PID")
    owner_parser.add_argument("--lock", required=True, type=absolute_path)
    owner_parser.add_argument("--with-token", action="store_true")

    verify_parser = subparsers.add_parser("verify-held", help="校验引擎继承的持锁 FD")
    verify_parser.add_argument("--lock", required=True, type=absolute_path)
    verify_parser.add_argument("--dir-fd", required=True, type=descriptor_number)
    verify_parser.add_argument("--fd", required=True, type=descriptor_number)
    verify_parser.add_argument("--pid", required=True, type=positive_pid)
    verify_parser.add_argument("--token", required=True)

    request_parser = subparsers.add_parser("write-request", help="原子写入停止请求")
    request_parser.add_argument("--path", required=True, type=absolute_path)
    request_parser.add_argument("--value", required=True)

    state_parser = subparsers.add_parser("read-state-pgid", help="安全读取负载进程组")
    state_parser.add_argument("--path", required=True, type=absolute_path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.action == "run":
            return run_locked(args)
        if args.action == "clear-stale":
            return clear_stale(args)
        if args.action == "owner":
            return show_owner(args)
        if args.action == "verify-held":
            try:
                return verify_held(args)
            except OSError as error:
                raise LockError(
                    "继承锁 FD 校验失败，系统错误码 {}".format(error.errno)
                ) from error
        if args.action == "write-request":
            return write_request(args)
        if args.action == "read-state-pgid":
            return read_state_pgid(args)
    except (LockError, OSError) as error:
        print("engine_lock: {}".format(error), file=sys.stderr)
        return 126
    return 2


if __name__ == "__main__":
    sys.exit(main())

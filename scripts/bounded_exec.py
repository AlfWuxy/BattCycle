#!/usr/bin/env python3
"""在固定时限内执行一个本地子进程，并确保它被回收。"""

import argparse
import os
import signal
import subprocess
import sys
from typing import Optional, Sequence


MIN_TIMEOUT_SECONDS = 1.0
MAX_TIMEOUT_SECONDS = 30.0
TERMINATE_GRACE_SECONDS = 1.0


def bounded_timeout(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("timeout 必须是数字") from error
    if not MIN_TIMEOUT_SECONDS <= parsed <= MAX_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError(
            "timeout 必须位于 {} 到 {} 秒之间".format(
                MIN_TIMEOUT_SECONDS, MAX_TIMEOUT_SECONDS
            )
        )
    return parsed


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="有界执行 BattCycle 外部命令")
    parser.add_argument("--timeout", required=True, type=bounded_timeout)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("缺少待执行命令")
    if not os.path.isabs(args.command[0]):
        parser.error("可执行文件必须使用绝对路径")
    return args


def run(command: Sequence[str], timeout: float) -> int:
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL)

    def forward_signal(signum, _frame):
        if process.poll() is None:
            try:
                process.send_signal(signum)
            except ProcessLookupError:
                pass

    previous_handlers = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous_handlers[signum] = signal.signal(signum, forward_signal)

    try:
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(
                "bounded_exec: 命令超过 {:.1f} 秒，正在终止: {}".format(
                    timeout, command[0]
                ),
                file=sys.stderr,
            )
            process.terminate()
            try:
                process.wait(timeout=TERMINATE_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            return 124
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        return run(args.command, args.timeout)
    except (OSError, ValueError) as error:
        print("bounded_exec: 无法执行命令: {}".format(error), file=sys.stderr)
        return 126


if __name__ == "__main__":
    sys.exit(main())

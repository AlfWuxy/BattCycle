#!/usr/bin/env python3
"""为 BattCycle 引擎与负载进程组提供可验证的身份标记。"""

import os
import signal
import sys
from typing import Sequence


VALID_ROLES = {"engine", "workload"}


def valid_token(value: str) -> bool:
    return len(value) == 32 and all(
        character in "0123456789abcdef" for character in value
    )


def main(argv: Sequence[str]) -> int:
    if (
        len(argv) != 5
        or argv[1] != "--role"
        or argv[2] not in VALID_ROLES
        or argv[3] != "--instance-token"
        or not valid_token(argv[4])
    ):
        print(
            "process_group_marker: 用法: --role engine|workload --instance-token <32位十六进制>",
            file=sys.stderr,
        )
        return 2
    if os.environ.get("BATTCYCLE_INSTANCE_TOKEN") != argv[4]:
        print("process_group_marker: 实例 token 与环境记录不一致", file=sys.stderr)
        return 1

    running = True

    def stop(_signal_number: int, _frame: object) -> None:
        nonlocal running
        running = False

    def keep_identity(_signal_number: int, _frame: object) -> None:
        # 组级 TERM 期间保留 token 身份，供宽限后的 KILL 再认证。
        return

    signal.signal(signal.SIGTERM, keep_identity)
    for signal_number in (signal.SIGINT, signal.SIGHUP):
        signal.signal(signal_number, stop)

    while running:
        signal.pause()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

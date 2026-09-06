#!/usr/bin/env python3
"""在独立进程组中原位 exec；可新建会话时同时隔离会话，供 Swift 精确清理。"""

import errno
import os
import sys
from typing import Optional, Sequence


def normalized_command(argv: Optional[Sequence[str]] = None) -> list[str]:
    values = list(sys.argv[1:] if argv is None else argv)
    if values and values[0] == "--":
        values = values[1:]
    if not values:
        raise ValueError("缺少待执行命令")
    if not os.path.isabs(values[0]):
        raise ValueError("可执行文件必须使用绝对路径")
    return values


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        command = normalized_command(argv)
        try:
            os.setsid()
        except OSError as error:
            # Foundation Process 可能已建立以子进程 PID 为首的独立组。
            # 此时 setsid 返回 EPERM；仅在组身份可证实且未与父进程共享时保留该组。
            pid = os.getpid()
            if (
                error.errno != errno.EPERM
                or os.getpgrp() != pid
                or os.getpgid(os.getppid()) == pid
            ):
                raise
        os.execve(command[0], command, os.environ.copy())
    except (OSError, ValueError) as error:
        print("process_group_exec: {}".format(error), file=sys.stderr)
        return 126
    return 126


if __name__ == "__main__":
    sys.exit(main())

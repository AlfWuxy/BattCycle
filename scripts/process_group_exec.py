#!/usr/bin/env python3
"""把命令放入独立会话后原位 exec，供 Swift 精确终止整组进程。"""

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
        os.setsid()
        os.execve(command[0], command, os.environ.copy())
    except (OSError, ValueError) as error:
        print("process_group_exec: {}".format(error), file=sys.stderr)
        return 126
    return 126


if __name__ == "__main__":
    sys.exit(main())

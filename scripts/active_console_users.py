#!/usr/bin/env python3
"""检查启动时是否存在另一个活跃的 macOS 控制台账号。"""

from __future__ import annotations

import os
import pwd
import subprocess
import sys


WHO_COMMAND = ("/usr/bin/who",)
WHO_TIMEOUT_SECONDS = 3


class ConsoleUserError(RuntimeError):
    """控制台账号状态无法安全确认。"""


def parse_console_users(payload: str) -> set[str]:
    """只读取 who 输出中终端列严格等于 console 的账号。"""
    users: set[str] = set()
    for raw_line in payload.splitlines():
        fields = raw_line.split()
        if len(fields) >= 2 and fields[1] == "console" and fields[0]:
            users.add(fields[0])
    return users


def validate_console_users(payload: str, current_user: str) -> set[str]:
    """允许零个控制台账号或仅当前账号，拒绝任何不同账号。"""
    users = parse_console_users(payload)
    if len(users) > 1 or (users and current_user not in users):
        listed = ", ".join(sorted(users)) or "无"
        raise ConsoleUserError(
            "检测到不同的活跃控制台账号，BattCycle 仅支持启动时单一账号：{}".format(
                listed
            )
        )
    return users


def read_console_sessions() -> str:
    """通过固定系统命令读取会话；失败或超时一律 fail closed。"""
    try:
        result = subprocess.run(
            WHO_COMMAND,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=WHO_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ConsoleUserError("无法读取 macOS 控制台账号：{}".format(error)) from error
    if result.returncode != 0:
        raise ConsoleUserError("macOS 控制台账号检查失败")
    return result.stdout


def main() -> int:
    if os.geteuid() == 0:
        print("active_console_users: 拒绝以 root 身份检查启动边界", file=sys.stderr)
        return 1
    try:
        current_user = pwd.getpwuid(os.geteuid()).pw_name
        validate_console_users(read_console_sessions(), current_user)
    except (KeyError, ConsoleUserError) as error:
        print("active_console_users: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

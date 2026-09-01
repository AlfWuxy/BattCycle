#!/usr/bin/env python3
"""严格读取并规范化 BattCycle 的本地 JSON 配置。"""

import argparse
import json
import os
import stat
import sys
import time
from typing import Dict, Iterable, Optional, Tuple


MAX_CONFIG_BYTES = 16 * 1024
MAX_STOP_DELAY_SECONDS = 24 * 60 * 60

EXPECTED_FIELDS: Dict[str, int] = {
    "upperLimit": 80,
    "lowerLimit": 30,
    "gpuSize": 2048,
    "cpuJobs": 4,
    "pollSeconds": 10,
    "stopAtEpoch": 0,
}

FIELD_RANGES: Dict[str, Tuple[int, int]] = {
    "upperLimit": (50, 100),
    "lowerLimit": (20, 80),
    "cpuJobs": (1, 16),
    # 最长轮询时间必须短于 10 分钟的适配器自动恢复窗口。
    "pollSeconds": (5, 60),
}

OUTPUT_ORDER = (
    "upperLimit",
    "lowerLimit",
    "gpuSize",
    "cpuJobs",
    "pollSeconds",
    "stopAtEpoch",
)


class ConfigError(ValueError):
    """配置不满足安全约束。"""


def _reject_duplicate_keys(pairs: Iterable[Tuple[str, object]]) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ConfigError("配置包含重复字段: {}".format(key))
        result[key] = value
    return result


def _reject_constant(value: str) -> object:
    raise ConfigError("配置包含无效数值: {}".format(value))


def _read_config_text(path: str) -> str:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)

    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        raise ConfigError("配置文件不存在: {}".format(path))
    except OSError as error:
        raise ConfigError("无法安全读取配置: {}".format(error)) from error

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ConfigError("配置必须是普通文件")
        if metadata.st_size > MAX_CONFIG_BYTES:
            raise ConfigError("配置文件超过 {} 字节".format(MAX_CONFIG_BYTES))
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            descriptor = -1
            return handle.read(MAX_CONFIG_BYTES + 1)
    except UnicodeDecodeError as error:
        raise ConfigError("配置必须使用 UTF-8 编码") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _require_plain_int(name: str, value: object) -> int:
    # bool 是 int 的子类，因此必须使用精确类型检查。
    if type(value) is not int:
        raise ConfigError("{} 必须是整数".format(name))
    return value


def validate_config(raw: object, now: Optional[int] = None) -> Dict[str, int]:
    if not isinstance(raw, dict):
        raise ConfigError("配置顶层必须是 JSON 对象")

    unknown = sorted(set(raw) - set(EXPECTED_FIELDS))
    if unknown:
        raise ConfigError("配置包含未知字段: {}".format(", ".join(unknown)))
    missing = sorted(set(EXPECTED_FIELDS) - set(raw))
    if missing:
        raise ConfigError("配置缺少字段: {}".format(", ".join(missing)))

    config = dict(raw)

    for name, bounds in FIELD_RANGES.items():
        value = _require_plain_int(name, config[name])
        minimum, maximum = bounds
        if value < minimum or value > maximum:
            raise ConfigError(
                "{} 必须位于 {} 到 {} 之间".format(name, minimum, maximum)
            )

    gpu_size = _require_plain_int("gpuSize", config["gpuSize"])
    if gpu_size not in (2048, 4096, 8192):
        raise ConfigError("gpuSize 只支持 2048、4096 或 8192")

    if config["upperLimit"] - config["lowerLimit"] < 5:
        raise ConfigError("upperLimit 与 lowerLimit 至少需要相差 5")

    stop_at = _require_plain_int("stopAtEpoch", config["stopAtEpoch"])
    current = int(time.time()) if now is None else int(now)
    if stop_at <= current:
        raise ConfigError("stopAtEpoch 已经过期")
    if stop_at > current + MAX_STOP_DELAY_SECONDS:
        raise ConfigError("stopAtEpoch 不能超过未来 24 小时")

    return {name: int(config[name]) for name in OUTPUT_ORDER}


def load_config(path: str, now: Optional[int] = None) -> Dict[str, int]:
    text = _read_config_text(path)
    try:
        raw = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except ConfigError:
        raise
    except json.JSONDecodeError as error:
        raise ConfigError("JSON 格式无效: {}".format(error.msg)) from error

    return validate_config(raw, now=now)


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="验证并规范化 BattCycle 配置")
    parser.add_argument("config", help="包含全部六个字段的配置文件路径")
    parser.add_argument("--now", type=int, help="仅供确定性验证使用的当前 Unix 时间")
    args = parser.parse_args(list(argv) if argv is not None else None)

    try:
        config = load_config(args.config, now=args.now)
    except ConfigError as error:
        print("配置错误: {}".format(error), file=sys.stderr)
        return 2

    # 每行只输出一个已经通过范围校验的十进制整数，供 zsh 按位置读取。
    for name in OUTPUT_ORDER:
        print(config[name])
    return 0


if __name__ == "__main__":
    sys.exit(main())

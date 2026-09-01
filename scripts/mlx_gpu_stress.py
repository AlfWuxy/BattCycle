#!/usr/bin/env python3
"""在严格资源边界内运行 MLX GPU 矩阵负载。"""

import argparse
import math
import time
from typing import Optional, Sequence


ALLOWED_SIZES = (2048, 4096, 8192)
MIN_SECONDS = 1.0
MAX_SECONDS = 600.0


def bounded_size(value: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError as error:
        raise argparse.ArgumentTypeError("size 必须是整数") from error
    if parsed not in ALLOWED_SIZES:
        raise argparse.ArgumentTypeError(
            "size 只支持 {}".format(" / ".join(str(item) for item in ALLOWED_SIZES))
        )
    return parsed


def bounded_seconds(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("seconds 必须是数字") from error
    if not math.isfinite(parsed) or parsed < MIN_SECONDS or parsed > MAX_SECONDS:
        raise argparse.ArgumentTypeError(
            "seconds 必须位于 {} 到 {} 之间".format(MIN_SECONDS, MAX_SECONDS)
        )
    return parsed


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="运行有边界的 MLX GPU 放电负载")
    parser.add_argument("--size", type=bounded_size, default=4096)
    parser.add_argument("--seconds", type=bounded_seconds, default=30.0)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> None:
    args = parse_args(argv)

    # 延迟导入可让参数校验和帮助命令在未安装 MLX 时安全运行。
    import mlx.core as mx

    mx.set_default_device(mx.gpu)
    left = mx.random.normal((args.size, args.size), dtype=mx.float32)
    right = mx.random.normal((args.size, args.size), dtype=mx.float32)
    mx.eval(left, right)

    start = time.monotonic()
    iterations = 0
    checksum = 0.0

    while time.monotonic() - start < args.seconds:
        product = left @ right
        checksum = float(mx.sum(product).item())
        iterations += 1

    elapsed = time.monotonic() - start
    print(
        "mlx_gpu_stress done size={} seconds={:.2f} iterations={} checksum={:.4e}".format(
            args.size,
            elapsed,
            iterations,
            checksum,
        )
    )


if __name__ == "__main__":
    main()

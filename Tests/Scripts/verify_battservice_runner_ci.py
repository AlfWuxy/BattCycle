#!/usr/bin/env python3
"""仅在 GitHub Actions 编译并验证真实 Swift 命令运行器，不调用电源服务。"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]

# 测试扩展与生产源码处于同一文件，仅借此访问 private run；不复制其实现。
SWIFT_HARNESS = r'''

private struct RunnerCheckError: Error, CustomStringConvertible {
    let description: String
}

extension BattService {
    fileprivate static func verifyCommandRunner(fixture: String, manifest: String) throws {
        let normal = try run(
            URL(fileURLWithPath: "/bin/echo"),
            arguments: ["normal command verified"],
            timeout: 5
        )
        guard normal.status == 0, normal.output == "normal command verified" else {
            throw RunnerCheckError(description: "正常命令失败：\(normal.status) \(normal.output)")
        }
        print("PASS: exact BattService.run normal command")

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try run(
                URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-I", fixture, manifest],
                timeout: 2
            )
            throw RunnerCheckError(description: "超时夹具意外返回：\(result.status) \(result.output)")
        } catch ServiceError.timedOut {
            // 仅确认清理完成的超时可通过；cleanupUnconfirmed 必须让 CI 失败。
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        guard elapsed < 10 else {
            throw RunnerCheckError(description: "超时清理超过边界：\(elapsed) 秒")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Int],
              let groupValue = record["group"], let childValue = record["child"],
              let group = Int32(exactly: groupValue), let child = Int32(exactly: childValue),
              group > 1, child > 1, group != getpgrp(), record["termIgnored"] == 1 else {
            throw RunnerCheckError(description: "超时夹具未准备好独立进程组和忽略 TERM 的子进程")
        }
        guard FileManager.default.fileExists(atPath: manifest + ".leader-term") else {
            throw RunnerCheckError(description: "未确认 leader 在 TERM 时退出")
        }
        let groupGone = Darwin.kill(-group, 0) == -1 && errno == ESRCH
        let childGone = Darwin.kill(child, 0) == -1 && errno == ESRCH
        guard groupGone, childGone else {
            throw RunnerCheckError(description: "超时后进程组或忽略 TERM 的子进程仍存在")
        }
        print("PASS: exact BattService.run removed TERM-surviving child in \(elapsed) seconds")
    }
}

@main
private enum RunnerVerificationMain {
    static func main() {
        do {
            guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
                  CommandLine.arguments.count == 3 else {
                throw RunnerCheckError(description: "运行器验证仅允许 GitHub Actions 与两个夹具参数")
            }
            try BattService.verifyCommandRunner(
                fixture: CommandLine.arguments[1], manifest: CommandLine.arguments[2]
            )
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
'''


PROCESS_FIXTURE = r'''
import json
import os
from pathlib import Path
import signal
import sys
import time

manifest = Path(sys.argv[1])
leader = os.getpid()
deadline = time.monotonic() + 15

def leader_term(_signal, _frame):
    manifest.with_name(manifest.name + ".leader-term").write_text("TERM\n", encoding="utf-8")
    os._exit(0)

signal.signal(signal.SIGTERM, leader_term)
child = os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    # 先安装处理规则再发布身份；没有就绪文件时验证不得通过。
    manifest.write_text(json.dumps({
        "group": os.getpgrp(), "leader": leader, "child": os.getpid(), "termIgnored": 1
    }), encoding="utf-8")
while time.monotonic() < deadline:
    time.sleep(0.05)
# 即便 CI 验证程序提前退出，夹具也会自行结束，不持续占用 runner。
os._exit(0)
'''


def cleanup_fixture(manifest: Path) -> None:
    """只清理本次临时夹具且当前身份仍匹配的进程组。"""
    if not manifest.exists():
        return
    record = json.loads(manifest.read_text(encoding="utf-8"))
    group, child, leader = (record[key] for key in ("group", "child", "leader"))
    if not all(type(value) is int and value > 1 for value in (group, child, leader)):
        raise RuntimeError("夹具进程身份无效，拒绝清理")
    if group != leader or group == os.getpgrp():
        raise RuntimeError("夹具未处于自身进程组，拒绝清理")
    for pid in (child, leader):
        try:
            if os.getpgid(pid) == group:
                os.killpg(group, signal.SIGKILL)
                return
        except ProcessLookupError:
            continue


def run_harness(binary: Path, fixture: Path, manifest: Path, environment: dict) -> None:
    # 外层组只属于本次验证器；被测命令仍由生产启动器创建自己的进程组。
    process = subprocess.Popen(
        [str(binary), str(fixture), str(manifest)], env=environment,
        start_new_session=True,
    )
    try:
        status = process.wait(timeout=25)
        if status != 0:
            raise RuntimeError("真实 Swift 运行器验证失败，退出码 {}".format(status))
    finally:
        try:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
        finally:
            cleanup_fixture(manifest)


def main() -> int:
    # 必须在解析参数、编译或创建子进程之前拒绝本机运行。
    if os.environ.get("GITHUB_ACTIONS") != "true":
        print("此验证只允许 GitHub Actions 执行；不得在本机运行。", file=sys.stderr)
        return 2
    if sys.platform != "darwin":
        print("此验证需要 GitHub 托管 macOS runner。", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-path", required=True, type=Path)
    arguments = parser.parse_args()
    bin_path = arguments.bin_path.resolve()
    objects = sorted((bin_path / "BattCycleCore.build").glob("*.o"))
    if not objects or not (bin_path / "Modules" / "BattCycleCore.swiftmodule").exists():
        raise RuntimeError("先在 CI 构建 debug BattCycleCore，再传入其 bin path")
    compiler = shutil.which("swiftc")
    if compiler is None:
        raise RuntimeError("CI 找不到 swiftc")

    source = (ROOT / "Sources" / "BattCycle" / "BattService.swift").read_bytes()
    print("Exact BattService.swift SHA-256: " + hashlib.sha256(source).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="battservice-ci-") as temporary:
        directory = Path(temporary)
        combined_source = directory / "BattServiceHarness.swift"
        combined_source.write_bytes(source + SWIFT_HARNESS.encode("utf-8"))
        if combined_source.read_bytes()[:len(source)] != source:
            raise RuntimeError("生产源码前缀发生变化")
        scripts = directory / "scripts"
        scripts.mkdir()
        shutil.copy2(ROOT / "scripts" / "process_group_exec.py", scripts / "process_group_exec.py")
        fixture = directory / "process_fixture.py"
        fixture.write_text(PROCESS_FIXTURE, encoding="utf-8")
        binary = directory / "runner"
        subprocess.run(
            [compiler, "-parse-as-library", "-D", "DEBUG", "-module-cache-path",
             str(directory / "module-cache"), "-I", str(bin_path / "Modules"),
             str(combined_source), *map(str, objects), "-framework", "IOKit", "-o", str(binary)],
            check=True, timeout=90,
        )
        environment = os.environ.copy()
        environment["BATTCYCLE_SCRIPTS"] = str(scripts)
        run_harness(binary, fixture, directory / "fixture.json", environment)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

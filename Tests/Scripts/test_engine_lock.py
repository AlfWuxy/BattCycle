import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOCK_TOOL = ROOT / "scripts" / "engine_lock.py"
GROUP_MARKER = ROOT / "scripts" / "process_group_marker.py"
CONTROL = ROOT / "scripts" / "battcycle"


class EngineLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="battcycle-lock-")
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.lock = base / "run.lock"
        self.pid_file = base / "run.pid"

    def command(self, executable, *arguments, append_token=False):
        command = [
            sys.executable,
            str(LOCK_TOOL),
            "run",
            "--lock",
            str(self.lock),
            "--pid-file",
            str(self.pid_file),
        ]
        if append_token:
            command.append("--append-token")
        return command + ["--", executable, *arguments]

    def wait_for_pid(self):
        for _ in range(100):
            if self.pid_file.is_file():
                return int(self.pid_file.read_text(encoding="ascii").strip())
            time.sleep(0.02)
        self.fail("锁持有者未发布 PID")

    def test_kernel_lock_rejects_second_instance_and_clears_after_exit(self):
        first = subprocess.Popen(
            self.command("/bin/sleep", "5"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: first.poll() is None and first.kill())
        owner = self.wait_for_pid()
        self.assertEqual(owner, first.pid)

        second = subprocess.run(
            self.command("/usr/bin/true"),
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(second.returncode, 75, second.stderr)

        owner_result = subprocess.run(
            [
                sys.executable,
                str(LOCK_TOOL),
                "owner",
                "--lock",
                str(self.lock),
                "--with-token",
            ],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(owner_result.returncode, 0, owner_result.stderr)
        owner_pid, owner_token = owner_result.stdout.strip().split(" ")
        self.assertEqual(int(owner_pid), first.pid)
        self.assertEqual(len(owner_token), 32)
        self.assertTrue(all(character in "0123456789abcdef" for character in owner_token))

        busy_clear = subprocess.run(
            [
                sys.executable,
                str(LOCK_TOOL),
                "clear-stale",
                "--lock",
                str(self.lock),
                "--pid-file",
                str(self.pid_file),
            ],
            timeout=2,
            check=False,
        )
        self.assertEqual(busy_clear.returncode, 75)

        first.terminate()
        first.wait(timeout=2)
        idle_owner = subprocess.run(
            [sys.executable, str(LOCK_TOOL), "owner", "--lock", str(self.lock)],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(idle_owner.returncode, 1, idle_owner.stderr)

        cleared = subprocess.run(
            [
                sys.executable,
                str(LOCK_TOOL),
                "clear-stale",
                "--lock",
                str(self.lock),
                "--pid-file",
                str(self.pid_file),
            ],
            timeout=2,
            check=False,
        )
        self.assertEqual(cleared.returncode, 0)
        self.assertFalse(self.pid_file.exists())
        self.assertEqual(self.lock.read_bytes(), b"")

    def test_verify_held_accepts_the_inherited_open_file_description(self):
        check = (
            'exec "$1" "$2" verify-held --lock "$3" '
            '--dir-fd "$BATTCYCLE_LOCK_DIR_FD" '
            '--fd "$BATTCYCLE_LOCK_FD" --pid "$BATTCYCLE_ENGINE_PID" '
            '--token "$BATTCYCLE_INSTANCE_TOKEN"'
        )
        result = subprocess.run(
            self.command(
                "/bin/zsh",
                "-c",
                check,
                "_",
                sys.executable,
                str(LOCK_TOOL),
                str(self.lock),
            ),
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_verify_held_rejects_a_separately_opened_descriptor(self):
        forge = """
import os
import sys

lock_path, tool_path = sys.argv[1:]
descriptor = os.open(lock_path, os.O_RDWR)
os.set_inheritable(descriptor, True)
environment = os.environ.copy()
environment["BATTCYCLE_LOCK_FD"] = str(descriptor)
os.execve(
    sys.executable,
    [
        sys.executable,
        tool_path,
        "verify-held",
        "--lock",
        lock_path,
        "--dir-fd",
        environment["BATTCYCLE_LOCK_DIR_FD"],
        "--fd",
        str(descriptor),
        "--pid",
        environment["BATTCYCLE_ENGINE_PID"],
        "--token",
        environment["BATTCYCLE_INSTANCE_TOKEN"],
    ],
    environment,
)
"""
        result = subprocess.run(
            self.command(sys.executable, "-c", forge, str(self.lock), str(LOCK_TOOL)),
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(result.returncode, 126)
        self.assertIn("继承 FD 不属于当前锁持有者", result.stderr)

    def test_verify_held_rejects_a_separately_opened_directory_descriptor(self):
        forge = """
import os
import sys

lock_path, tool_path = sys.argv[1:]
directory = os.open(os.path.dirname(lock_path), os.O_RDONLY)
os.set_inheritable(directory, True)
environment = os.environ.copy()
environment["BATTCYCLE_LOCK_DIR_FD"] = str(directory)
os.execve(
    sys.executable,
    [
        sys.executable,
        tool_path,
        "verify-held",
        "--lock",
        lock_path,
        "--dir-fd",
        str(directory),
        "--fd",
        environment["BATTCYCLE_LOCK_FD"],
        "--pid",
        environment["BATTCYCLE_ENGINE_PID"],
        "--token",
        environment["BATTCYCLE_INSTANCE_TOKEN"],
    ],
    environment,
)
"""
        result = subprocess.run(
            self.command(sys.executable, "-c", forge, str(self.lock), str(LOCK_TOOL)),
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(result.returncode, 126)
        self.assertIn("继承锁目录 FD 不属于当前锁持有者", result.stderr)

    def test_directory_anchor_rejects_second_instance_after_pathname_split(self):
        for mutation in ("unlink", "rename", "hardlink"):
            with self.subTest(mutation=mutation):
                base = Path(self.temporary.name) / mutation
                base.mkdir()
                lock = base / "run.lock"
                pid_file = base / "run.pid"
                alias = base / "run.lock.alias"

                def command(executable, *arguments):
                    return [
                        sys.executable,
                        str(LOCK_TOOL),
                        "run",
                        "--lock",
                        str(lock),
                        "--pid-file",
                        str(pid_file),
                        "--",
                        executable,
                        *arguments,
                    ]

                first = subprocess.Popen(
                    command("/bin/sleep", "5"),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                self.addCleanup(lambda process=first: process.poll() is None and process.kill())
                for _ in range(100):
                    if pid_file.is_file() and lock.is_file():
                        break
                    time.sleep(0.02)
                else:
                    self.fail("锁持有者未发布运行记录")
                original_pid = pid_file.read_text(encoding="ascii")

                if mutation == "unlink":
                    lock.unlink()
                elif mutation == "rename":
                    lock.rename(alias)
                else:
                    os.link(lock, alias)

                second = subprocess.run(
                    command("/usr/bin/true"),
                    capture_output=True,
                    text=True,
                    timeout=2,
                    check=False,
                )
                self.assertEqual(second.returncode, 75, second.stderr)
                self.assertEqual(pid_file.read_text(encoding="ascii"), original_pid)
                first.terminate()
                first.wait(timeout=2)

    def test_verify_held_rejects_unlink_rename_and_hardlink(self):
        mutation_program = r"""
import os
import sys

mutation, lock_path, alias_path, tool_path = sys.argv[1:]
if mutation == "unlink":
    os.unlink(lock_path)
elif mutation == "rename":
    os.rename(lock_path, alias_path)
elif mutation == "hardlink":
    os.link(lock_path, alias_path)
else:
    raise RuntimeError("unknown mutation")

environment = os.environ.copy()
os.execve(
    sys.executable,
    [
        sys.executable,
        tool_path,
        "verify-held",
        "--lock",
        lock_path,
        "--dir-fd",
        environment["BATTCYCLE_LOCK_DIR_FD"],
        "--fd",
        environment["BATTCYCLE_LOCK_FD"],
        "--pid",
        environment["BATTCYCLE_ENGINE_PID"],
        "--token",
        environment["BATTCYCLE_INSTANCE_TOKEN"],
    ],
    environment,
)
"""
        for mutation in ("unlink", "rename", "hardlink"):
            with self.subTest(mutation=mutation):
                base = Path(self.temporary.name) / ("verify-" + mutation)
                base.mkdir()
                lock = base / "run.lock"
                pid_file = base / "run.pid"
                alias = base / "run.lock.alias"
                result = subprocess.run(
                    [
                        sys.executable,
                        str(LOCK_TOOL),
                        "run",
                        "--lock",
                        str(lock),
                        "--pid-file",
                        str(pid_file),
                        "--",
                        sys.executable,
                        "-c",
                        mutation_program,
                        mutation,
                        str(lock),
                        str(alias),
                        str(LOCK_TOOL),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=2,
                    check=False,
                )
                self.assertEqual(result.returncode, 126, result.stderr)
                if mutation == "hardlink":
                    self.assertIn("锁文件链接数必须为 1", result.stderr)

    def test_secure_request_writer_replaces_a_symlink_without_touching_target(self):
        request = Path(self.temporary.name) / "stop.request"
        victim = Path(self.temporary.name) / "victim.txt"
        victim.write_text("keep\n", encoding="utf-8")
        request.symlink_to(victim)

        result = subprocess.run(
            [
                sys.executable,
                str(LOCK_TOOL),
                "write-request",
                "--path",
                str(request),
                "--value",
                "1234567890",
            ],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(request.is_symlink())
        self.assertEqual(request.read_text(encoding="utf-8"), "1234567890\n")
        self.assertEqual(request.stat().st_mode & 0o777, 0o600)
        self.assertEqual(victim.read_text(encoding="utf-8"), "keep\n")
        self.assertEqual(list(Path(self.temporary.name).glob(".stop.request.*.tmp")), [])

    def test_state_reader_accepts_only_a_private_owned_regular_json_file(self):
        state = Path(self.temporary.name) / "state.json"
        state.write_text(json.dumps({"stressPgid": 4321}), encoding="utf-8")
        state.chmod(0o600)
        valid = subprocess.run(
            [sys.executable, str(LOCK_TOOL), "read-state-pgid", "--path", str(state)],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(valid.stdout.strip(), "4321")

        state.write_text(json.dumps({"stressPgid": None}), encoding="utf-8")
        state.chmod(0o600)
        absent = subprocess.run(
            [sys.executable, str(LOCK_TOOL), "read-state-pgid", "--path", str(state)],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(absent.returncode, 3, absent.stderr)

    def test_process_group_marker_requires_matching_environment_token(self):
        token = "a" * 32
        environment = os.environ.copy()
        environment["BATTCYCLE_INSTANCE_TOKEN"] = token
        marker = subprocess.Popen(
            [
                sys.executable,
                str(GROUP_MARKER),
                "--role",
                "engine",
                "--instance-token",
                token,
            ],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: marker.poll() is None and marker.kill())
        time.sleep(0.2)
        self.assertIsNone(marker.poll())
        marker.terminate()
        time.sleep(0.05)
        self.assertIsNone(marker.poll())
        marker.send_signal(signal.SIGHUP)
        self.assertEqual(marker.wait(timeout=2), 0)

        interrupt_marker = subprocess.Popen(
            [
                sys.executable,
                str(GROUP_MARKER),
                "--role",
                "workload",
                "--instance-token",
                token,
            ],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(
            lambda: interrupt_marker.poll() is None and interrupt_marker.kill()
        )
        time.sleep(0.05)
        self.assertIsNone(interrupt_marker.poll())
        interrupt_marker.send_signal(signal.SIGINT)
        self.assertEqual(interrupt_marker.wait(timeout=2), 0)

        environment["BATTCYCLE_INSTANCE_TOKEN"] = "b" * 32
        mismatch = subprocess.run(
            [
                sys.executable,
                str(GROUP_MARKER),
                "--role",
                "workload",
                "--instance-token",
                token,
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(mismatch.returncode, 1)

    def test_token_is_random_and_passed_as_a_separate_argument(self):
        check = (
            'value="${1#--battcycle-instance-token=}"; '
            '[[ "$1" == --battcycle-instance-token=* && ${#value} -eq 32 '
            '&& "$value" != *[^0-9a-f]* ]]'
        )
        result = subprocess.run(
            self.command("/bin/zsh", "-c", check, "_", append_token=True),
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        cleared = subprocess.run(
            [
                sys.executable,
                str(LOCK_TOOL),
                "clear-stale",
                "--lock",
                str(self.lock),
                "--pid-file",
                str(self.pid_file),
            ],
            timeout=2,
            check=False,
        )
        self.assertEqual(cleared.returncode, 0)

    def test_relative_lock_path_is_rejected(self):
        result = subprocess.run(
            [
                sys.executable,
                str(LOCK_TOOL),
                "owner",
                "--lock",
                "run.lock",
            ],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(result.returncode, 2)


class BattcycleControlIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="battcycle-control-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.support = self.base / "support"
        self.support.mkdir(mode=0o700)
        self.state = self.support / "state.json"
        self.mock_ps = self.base / "mock-ps"
        self.mock_ps.write_text(
            '#!/bin/zsh\nprint -r -- "${MOCK_PS_ROWS:-}"\n',
            encoding="utf-8",
        )
        self.mock_ps.chmod(0o700)

        source = CONTROL.read_text(encoding="utf-8")
        prefix, separator, _dispatcher = source.partition('\ncmd="${1:-status}"')
        self.assertTrue(separator)
        self.prefix = prefix

    def run_functions(self, body, rows=""):
        harness = self.base / "identity-harness.zsh"
        harness.write_text(
            self.prefix
            + "\n"
            + "HERE={}\n".format(subprocess.list2cmdline([str(ROOT / "scripts")]))
            + "GROUP_MARKER={}\n".format(subprocess.list2cmdline([str(GROUP_MARKER)]))
            + "LOCK_TOOL={}\n".format(subprocess.list2cmdline([str(LOCK_TOOL)]))
            + "STATE={}\n".format(subprocess.list2cmdline([str(self.state)]))
            + "PS_BIN={}\n".format(subprocess.list2cmdline([str(self.mock_ps)]))
            + "set +e\n"
            + body
            + "\n",
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment["MOCK_PS_ROWS"] = rows
        return subprocess.run(
            ["/bin/zsh", str(harness)],
            env=environment,
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )

    def marker_row(self, pid, group_id, token, role="workload", uid=None):
        if uid is None:
            uid = os.geteuid()
        return "{} {} {} S /usr/bin/python3 {} --role {} --instance-token {}".format(
            uid,
            pid,
            group_id,
            GROUP_MARKER,
            role,
            token,
        )

    def test_unique_marker_discovery_rejects_wrong_token_missing_and_multiple(self):
        token = "a" * 32
        wrong_token = "b" * 32
        command = (
            'output="$(unique_marker_group {} workload)"; '
            'result_code=$?; print -- "$result_code:$output"'
        ).format(token)

        wrong = self.run_functions(
            command,
            self.marker_row(101, 4101, wrong_token),
        )
        self.assertEqual(wrong.returncode, 0, wrong.stderr)
        self.assertEqual(wrong.stdout.strip(), "3:")

        missing = self.run_functions(command)
        self.assertEqual(missing.returncode, 0, missing.stderr)
        self.assertEqual(missing.stdout.strip(), "3:")

        multiple = self.run_functions(
            command,
            "\n".join(
                [
                    self.marker_row(102, 4102, token),
                    self.marker_row(103, 4103, token),
                ]
            ),
        )
        self.assertEqual(multiple.returncode, 0, multiple.stderr)
        self.assertEqual(multiple.stdout.strip(), "4:")

    def test_marker_discovery_filters_euid_for_engine_and_workload_roles(self):
        current_uid = os.geteuid()
        foreign_uid = current_uid + 1
        for role in ("engine", "workload"):
            with self.subTest(role=role, case="foreign-ignored"):
                token = ("a" if role == "engine" else "b") * 32
                command = (
                    'output="$(unique_marker_group {} {})"; '
                    'result_code=$?; print -- "$result_code:$output"'
                ).format(token, role)
                result = self.run_functions(
                    command,
                    "\n".join(
                        [
                            self.marker_row(201, 5201, token, role, foreign_uid),
                            self.marker_row(202, 5202, token, role, current_uid),
                        ]
                    ),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "0:5202")

            with self.subTest(role=role, case="foreign-only-missing"):
                foreign_only = self.run_functions(
                    command,
                    self.marker_row(203, 5203, token, role, foreign_uid),
                )
                self.assertEqual(foreign_only.returncode, 0, foreign_only.stderr)
                self.assertEqual(foreign_only.stdout.strip(), "3:")

            with self.subTest(role=role, case="two-current-ambiguous"):
                ambiguous = self.run_functions(
                    command,
                    "\n".join(
                        [
                            self.marker_row(204, 5204, token, role, current_uid),
                            self.marker_row(205, 5205, token, role, current_uid),
                            self.marker_row(206, 5206, token, role, foreign_uid),
                        ]
                    ),
                )
                self.assertEqual(ambiguous.returncode, 0, ambiguous.stderr)
                self.assertEqual(ambiguous.stdout.strip(), "4:")

    def test_start_fallback_requires_one_exact_current_user_engine_marker(self):
        current_uid = os.geteuid()
        foreign_uid = current_uid + 1
        token = "e" * 32
        command = (
            'output="$(unique_current_user_engine_marker_group)"; '
            'result_code=$?; print -- "$result_code:$output"'
        )

        exact = self.run_functions(
            command,
            "\n".join(
                [
                    self.marker_row(301, 5301, token, "engine", foreign_uid),
                    self.marker_row(302, 5302, token, "workload", current_uid),
                    self.marker_row(303, 5303, token, "engine", current_uid),
                ]
            ),
        )
        self.assertEqual(exact.returncode, 0, exact.stderr)
        self.assertEqual(exact.stdout.strip(), "0:5303")

        loose = self.run_functions(
            command,
            self.marker_row(304, 5304, token, "engine", current_uid) + " --extra",
        )
        self.assertEqual(loose.returncode, 0, loose.stderr)
        self.assertEqual(loose.stdout.strip(), "3:")

        ambiguous = self.run_functions(
            command,
            "\n".join(
                [
                    self.marker_row(305, 5305, token, "engine", current_uid),
                    self.marker_row(306, 5306, "f" * 32, "engine", current_uid),
                ]
            ),
        )
        self.assertEqual(ambiguous.returncode, 0, ambiguous.stderr)
        self.assertEqual(ambiguous.stdout.strip(), "4:")

    def test_required_workload_recovery_uses_unique_marker_for_stale_state(self):
        token = "c" * 32
        self.state.write_text(json.dumps({"stressPgid": 9999}), encoding="utf-8")
        self.state.chmod(0o600)
        result = self.run_functions(
            (
                'output="$(authenticated_workload_group {} required)"; '
                'result_code=$?; print -- "$result_code:$output"'
            ).format(token),
            self.marker_row(104, 4204, token),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0:4204")

    def test_required_workload_recovery_works_before_state_is_published(self):
        token = "e" * 32
        result = self.run_functions(
            (
                'output="$(authenticated_workload_group {} required)"; '
                'result_code=$?; print -- "$result_code:$output"'
            ).format(token),
            self.marker_row(107, 4207, token),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0:4207")

    def test_required_workload_recovery_fails_for_zero_or_multiple_candidates(self):
        token = "d" * 32
        command = (
            'output="$(authenticated_workload_group {} required)"; '
            'result_code=$?; print -- "$result_code:$output"'
        ).format(token)
        missing = self.run_functions(command)
        self.assertEqual(missing.returncode, 0, missing.stderr)
        self.assertEqual(missing.stdout.strip(), "1:")

        multiple = self.run_functions(
            command,
            "\n".join(
                [
                    self.marker_row(105, 4205, token),
                    self.marker_row(106, 4206, token),
                ]
            ),
        )
        self.assertEqual(multiple.returncode, 0, multiple.stderr)
        self.assertEqual(multiple.stdout.strip(), "1:")

    def test_busy_kernel_lock_cannot_be_reported_as_released(self):
        result = self.run_functions(
            "clear_stale_runtime_files() { return 75; }; "
            "confirm_kernel_lock_released; print -- $?"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1")
        self.assertIn("内核锁仍被持有", result.stderr)

    def test_term_and_kill_both_require_fresh_marker_authentication(self):
        token = "f" * 32
        result = self.run_functions(
            "process_group_has_marker() {{ print -- \"auth:$1:$2:$3\"; return 1; }}; "
            "process_group_alive() {{ return 0; }}; "
            "signal_authenticated_group TERM 4301 {} workload; print -- term:$?; "
            "signal_authenticated_group KILL 4301 {} workload; print -- kill:$?".format(
                token,
                token,
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip().splitlines(),
            [
                "auth:4301:{}:workload".format(token),
                "term:1",
                "auth:4301:{}:workload".format(token),
                "kill:1",
            ],
        )

    def test_signal_race_treats_an_already_exited_group_as_success(self):
        token = "1" * 32
        result = self.run_functions(
            "process_group_has_marker() {{ return 1; }}; "
            "process_group_alive() {{ return 1; }}; "
            "signal_authenticated_group TERM 4302 {} workload; print -- term:$?; "
            "signal_authenticated_group KILL 4302 {} workload; print -- kill:$?".format(
                token,
                token,
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip().splitlines(), ["term:0", "kill:0"])


if __name__ == "__main__":
    unittest.main()

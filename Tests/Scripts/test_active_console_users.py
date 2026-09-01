import importlib.util
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "active_console_users.py"
SPEC = importlib.util.spec_from_file_location("active_console_users", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ActiveConsoleUsersTests(unittest.TestCase):
    def test_repeated_current_console_user_is_allowed(self):
        payload = (
            "imac console Sep 1 10:00\n"
            "imac console Sep 1 10:01\n"
            "other ttys001 Sep 1 10:02\n"
        )
        self.assertEqual(MODULE.validate_console_users(payload, "imac"), {"imac"})

    def test_zero_console_users_is_allowed_for_ci_and_internal_tests(self):
        payload = "runner ttys001 Sep 1 10:00\n"
        self.assertEqual(MODULE.validate_console_users(payload, "runner"), set())

    def test_different_console_user_is_rejected(self):
        with self.assertRaises(MODULE.ConsoleUserError):
            MODULE.validate_console_users("other console Sep 1 10:00\n", "imac")

    def test_two_distinct_console_users_are_rejected(self):
        payload = "imac console Sep 1 10:00\nother console Sep 1 10:01\n"
        with self.assertRaises(MODULE.ConsoleUserError):
            MODULE.validate_console_users(payload, "imac")

    def test_who_failure_is_fail_closed(self):
        original = MODULE.subprocess.run

        def failed_run(*_args, **_kwargs):
            return subprocess.CompletedProcess(MODULE.WHO_COMMAND, 1, "", "failure")

        MODULE.subprocess.run = failed_run
        try:
            with self.assertRaises(MODULE.ConsoleUserError):
                MODULE.read_console_sessions()
        finally:
            MODULE.subprocess.run = original


if __name__ == "__main__":
    unittest.main()

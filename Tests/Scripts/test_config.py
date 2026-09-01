import importlib.util
import json
import os
import time
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("无法加载测试模块: {}".format(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config_module = load_module(
    "battcycle_config", ROOT / "scripts" / "battcycle_config.py"
)
mlx_module = load_module(
    "mlx_gpu_stress", ROOT / "scripts" / "mlx_gpu_stress.py"
)
bounded_module = load_module(
    "bounded_exec", ROOT / "scripts" / "bounded_exec.py"
)
group_exec_module = load_module(
    "process_group_exec", ROOT / "scripts" / "process_group_exec.py"
)


class ConfigParserTests(unittest.TestCase):
    def setUp(self):
        self.now = 2_000_000_000
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "config.json"

    def write_json(self, value):
        self.path.write_text(json.dumps(value), encoding="utf-8")

    def valid_config(self):
        return {
            "upperLimit": 80,
            "lowerLimit": 30,
            "gpuSize": 2048,
            "cpuJobs": 4,
            "pollSeconds": 10,
            "stopAtEpoch": self.now + 3600,
        }

    def write_config(self, **overrides):
        config = self.valid_config()
        config.update(overrides)
        self.write_json(config)

    def test_missing_file_without_future_stop_is_rejected(self):
        with self.assertRaises(config_module.ConfigError):
            config_module.load_config(str(self.path), now=self.now)

    def test_valid_full_config_is_normalized(self):
        expected = self.valid_config()
        self.write_json(expected)
        self.assertEqual(
            config_module.load_config(str(self.path), now=self.now), expected
        )

    def test_unknown_and_removed_fields_are_rejected(self):
        for field in ("unexpected", "keepAwakeLidClosed"):
            with self.subTest(field=field):
                config = self.valid_config()
                config[field] = True
                self.write_json(config)
                with self.assertRaises(config_module.ConfigError):
                    config_module.load_config(str(self.path), now=self.now)

    def test_each_schema_field_is_required(self):
        for field in self.valid_config():
            with self.subTest(field=field):
                config = self.valid_config()
                del config[field]
                self.write_json(config)
                with self.assertRaises(config_module.ConfigError):
                    config_module.load_config(str(self.path), now=self.now)

    def test_type_injection_is_rejected(self):
        values = (True, "75; touch /tmp/injected", 75.0, [75], {"value": 75})
        for value in values:
            with self.subTest(value=value):
                self.write_config(upperLimit=value)
                with self.assertRaises(config_module.ConfigError):
                    config_module.load_config(str(self.path), now=self.now)

    def test_duplicate_keys_are_rejected(self):
        self.path.write_text(
            '{"upperLimit": 75, "upperLimit": 80}', encoding="utf-8"
        )
        with self.assertRaises(config_module.ConfigError):
            config_module.load_config(str(self.path), now=self.now)

    def test_non_object_top_level_is_rejected(self):
        self.path.write_text("[]", encoding="utf-8")
        with self.assertRaises(config_module.ConfigError):
            config_module.load_config(str(self.path), now=self.now)

    def test_numeric_ranges_are_enforced(self):
        invalid = {
            "upperLimit": (49, 101),
            "lowerLimit": (19, 81),
            "cpuJobs": (0, 17),
            "pollSeconds": (4, 61),
        }
        for field, values in invalid.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    self.write_config(**{field: value})
                    with self.assertRaises(config_module.ConfigError):
                        config_module.load_config(str(self.path), now=self.now)

    def test_charge_limits_require_five_percent_hysteresis(self):
        for upper, lower in ((60, 60), (80, 76)):
            with self.subTest(upper=upper, lower=lower):
                self.write_config(upperLimit=upper, lowerLimit=lower)
                with self.assertRaises(config_module.ConfigError):
                    config_module.load_config(str(self.path), now=self.now)

    def test_stop_epoch_accepts_next_24_hours(self):
        for value in (self.now + 1, self.now + 24 * 60 * 60):
            with self.subTest(value=value):
                self.write_config(stopAtEpoch=value)
                config = config_module.load_config(str(self.path), now=self.now)
                self.assertEqual(config["stopAtEpoch"], value)

    def test_expired_or_too_distant_stop_epoch_is_rejected(self):
        for value in (0, self.now - 1, self.now, self.now + 24 * 60 * 60 + 1):
            with self.subTest(value=value):
                self.write_config(stopAtEpoch=value)
                with self.assertRaises(config_module.ConfigError):
                    config_module.load_config(str(self.path), now=self.now)

    def test_gpu_size_is_allowlisted(self):
        for value in (2048, 4096, 8192):
            with self.subTest(value=value):
                self.write_config(gpuSize=value, stopAtEpoch=self.now + 60)
                config = config_module.load_config(str(self.path), now=self.now)
                self.assertEqual(config["gpuSize"], value)
        for value in (256, 1024, 2049, 16384):
            with self.subTest(value=value):
                self.write_config(gpuSize=value, stopAtEpoch=self.now + 60)
                with self.assertRaises(config_module.ConfigError):
                    config_module.load_config(str(self.path), now=self.now)

    def test_oversized_file_is_rejected(self):
        self.path.write_text(" " * (config_module.MAX_CONFIG_BYTES + 1), encoding="utf-8")
        with self.assertRaises(config_module.ConfigError):
            config_module.load_config(str(self.path), now=self.now)

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "平台不支持 O_NOFOLLOW")
    def test_symbolic_link_config_is_rejected(self):
        target = Path(self.temporary.name) / "target.json"
        target.write_text("{}", encoding="utf-8")
        self.path.symlink_to(target)
        with self.assertRaises(config_module.ConfigError):
            config_module.load_config(str(self.path), now=self.now)


class MLXArgumentTests(unittest.TestCase):
    def test_size_boundaries(self):
        self.assertEqual(mlx_module.bounded_size("2048"), 2048)
        self.assertEqual(mlx_module.bounded_size("4096"), 4096)
        self.assertEqual(mlx_module.bounded_size("8192"), 8192)
        for value in ("0", "256", "2049", "8193", "2.5", "bad"):
            with self.subTest(value=value):
                with self.assertRaises(Exception):
                    mlx_module.bounded_size(value)

    def test_seconds_rejects_non_finite_or_unbounded_values(self):
        self.assertEqual(mlx_module.bounded_seconds("1"), 1.0)
        self.assertEqual(mlx_module.bounded_seconds("600"), 600.0)
        for value in ("0", "601", "nan", "inf", "bad"):
            with self.subTest(value=value):
                with self.assertRaises(Exception):
                    mlx_module.bounded_seconds(value)


class ProcessBoundaryTests(unittest.TestCase):
    def test_bounded_timeout_range(self):
        self.assertEqual(bounded_module.bounded_timeout("1"), 1.0)
        self.assertEqual(bounded_module.bounded_timeout("30"), 30.0)
        for value in ("0", "31", "nan", "bad"):
            with self.subTest(value=value):
                with self.assertRaises(Exception):
                    bounded_module.bounded_timeout(value)

    def test_hung_child_is_killed_and_reaped(self):
        started = time.monotonic()
        status = bounded_module.run(["/bin/sleep", "5"], timeout=0.1)
        self.assertEqual(status, 124)
        self.assertLess(time.monotonic() - started, 2)

    def test_group_launcher_requires_absolute_command(self):
        self.assertEqual(
            group_exec_module.normalized_command(["--", "/bin/echo", "ok"]),
            ["/bin/echo", "ok"],
        )
        with self.assertRaises(ValueError):
            group_exec_module.normalized_command(["echo", "bad"])


if __name__ == "__main__":
    unittest.main()

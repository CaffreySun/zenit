#!/usr/bin/env python3
"""Offline batch preparation and strict Windows acceptance must fail closed."""
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import windows_batch as batch

class BatchContract(unittest.TestCase):
    def invoke(self, extra):
        with tempfile.TemporaryDirectory(prefix="zenit-batch-contract-") as directory:
            folder = Path(directory) / "payload"
            captured = []
            def bundle(plan, bin_dir, arch, out, startup):
                captured.extend(plan)
                (out / batch.queue.BATCH_BUNDLE).write_bytes(b"fixture")
                return "fixture-digest"
            with patch.object(sys, "argv", ["windows_batch", "--skip-build", *extra, "--output-dir", str(folder)]), \
                 patch.object(batch, "make_job", side_effect=bundle), \
                 patch.object(batch, "build", side_effect=AssertionError("unexpected build")), \
                 patch.object(batch.queue, "read_token", side_effect=AssertionError("unexpected credential access")), \
                 patch.object(batch.queue, "request", side_effect=AssertionError("unexpected network access")), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                result = batch.main()
            return result, captured

    def test_offline_strict_prepares_every_stage_without_credentials_or_network(self):
        code, plan = self.invoke(["--prepare-only", "--require-a11y"])
        self.assertEqual(code, 0)
        self.assertEqual(len(plan), 21)
        self.assertEqual(sum(p["kind"] == "e2e" for p in plan), 20)
        self.assertEqual(len({p["exe_name"] for p in plan}), 4)
        self.assertTrue(all(p["blocking"] for p in plan))

    def test_conflicting_accessibility_options_fail_before_bundling(self):
        with self.assertRaises(SystemExit) as error:
            self.invoke(["--prepare-only", "--require-a11y", "--no-a11y"])
        self.assertEqual(error.exception.code, 2)

    def test_missing_output_fails_before_build_or_network(self):
        with patch.object(sys, "argv", ["windows_batch", "--prepare-only"]), \
             patch.object(batch, "build", side_effect=AssertionError("unexpected build")), \
             patch.object(batch.queue, "read_token", side_effect=AssertionError("unexpected credential access")), \
             patch.object(batch.queue, "request", side_effect=AssertionError("unexpected network access")), \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                batch.main()
        self.assertEqual(error.exception.code, 2)

if __name__ == "__main__":
    unittest.main()

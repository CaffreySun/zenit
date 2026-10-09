#!/usr/bin/env python3
"""Offline batch preparation and strict Windows acceptance must fail closed."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
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

    def test_accessibility_suites_target_their_actual_application(self):
        plan = batch.stages(True)
        accessibility = {p["name"]: p["exe_name"] for p in plan if p["name"].startswith("accessibility")}
        self.assertEqual(accessibility.pop("accessibility"), batch.queue.E2E_APPS["render-gallery"])
        self.assertEqual(len(accessibility), 6)
        self.assertTrue(all(exe == batch.queue.E2E_APPS["storybook"] for exe in accessibility.values()))

    def test_conflicting_accessibility_options_fail_before_bundling(self):
        with self.assertRaises(SystemExit) as error:
            self.invoke(["--prepare-only", "--require-a11y", "--no-a11y"])
        self.assertEqual(error.exception.code, 2)

    def judge_evidence(self, error):
        with tempfile.TemporaryDirectory(prefix="zenit-stage-evidence-") as directory:
            stage_dir = Path(directory)
            (stage_dir / "stage-result.json").write_text(json.dumps({"exit_code": 0, "error": error}))
            summary = {"total": 1, "executed": 1, "passed": 1, "failed": 0, "aborted": 0, "failures": []}
            with zipfile.ZipFile(stage_dir / "windows-suite-session.zip", "w") as archive:
                archive.writestr("summary.json", json.dumps(summary))
            return batch.judge({"kind": "e2e", "minimum_cases": 1}, stage_dir)

    def test_stage_error_cannot_pass_with_successful_suite_and_exit_code(self):
        passed, detail = self.judge_evidence("shutdown cleanup failed")
        self.assertFalse(passed)
        self.assertIn("shutdown cleanup failed", detail)

    def test_clean_stage_evidence_passes(self):
        passed, detail = self.judge_evidence("")
        self.assertTrue(passed)
        self.assertEqual(detail, "1/1 passed")

    def completed_batch(self, state):
        with tempfile.TemporaryDirectory(prefix="zenit-batch-result-") as directory:
            root = Path(directory)
            output = io.StringIO()
            def bundle(plan, bin_dir, arch, out, startup):
                (out / batch.queue.BATCH_BUNDLE).write_bytes(b"fixture")
                return "fixture-digest"
            def request(base, token, method, route, *args):
                return state if route.startswith("/jobs/") else {}
            with patch.object(sys, "argv", ["windows_batch", "--skip-build", "--require-a11y"]), \
                 patch.object(batch.queue, "data_dir", return_value=root), \
                 patch.object(batch.queue, "read_token", return_value="fixture"), \
                 patch.object(batch.queue, "require_worker"), \
                 patch.object(batch.queue, "request", side_effect=request), \
                 patch.object(batch, "make_job", side_effect=bundle), \
                 patch.object(batch, "judge", return_value=(True, "all stage evidence passed")), \
                 contextlib.redirect_stdout(output):
                code = batch.main()
            reports = list(root.glob("jobs/*/batch-report.json"))
            self.assertEqual(len(reports), 1)
            self.assertTrue(all(row["passed"] for row in json.loads(reports[0].read_text())))
            return code, output.getvalue()

    def test_failed_batch_cannot_pass_even_when_every_stage_passes(self):
        code, output = self.completed_batch({"status": "failed", "error": "Batch upload failed after all stage archives were delivered"})
        self.assertEqual(code, 1)
        self.assertNotIn("==> PASSED", output)

    def test_successful_batch_and_all_stages_pass(self):
        code, output = self.completed_batch({"status": "passed", "error": ""})
        self.assertEqual(code, 0)
        self.assertIn("==> PASSED", output)

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

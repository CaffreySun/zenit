#!/usr/bin/env python3
"""One-shot Windows acceptance over the worker queue (VM or real hardware).

Build every executable once, bundle every suite for the worker, and ship them together with a
stage manifest in ONE job. The worker runs all stages locally (each app beside its bundled suite,
no harness request crosses the network) and returns each stage's evidence at the end. The host
then judges every stage exactly as the per-stage tools do: suite summaries, the Modal / Sheet /
Notification submitted-frame audits and the native D3D12 contract probe.

  python3 tools/windows_batch.py --base URL [--arch x86_64] [--artifact-dir BIN] [--skip-build]

Stages: the shared render/input gates (windows_shared_regression.PHASES), the native GPU contract
probe (scope all) and the UI Automation suites (reported, not blocking).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import windows_shared_regression as shared  # noqa: E402
import windows_vm_http as queue  # noqa: E402

REPO = queue.REPO
GPU_PROBE = queue.PROBES["gpu"][1]


def stages(include_a11y: bool) -> list[dict]:
    out = []
    for name, app, suite, minimum, _reuse, extra in shared.PHASES:
        modal = "--audit-modal-frames" in extra
        out.append({"name": name, "kind": "e2e", "exe_name": queue.E2E_APPS[app], "suite_source": suite,
                    "minimum_cases": minimum, "blocking": True, "filter": shared.STAGE_FILTERS.get(name, ""),
                    "capture_frames": modal or "--capture-frames" in extra, "trace_frames": modal,
                    "audit": "modal" if modal else {"sheet-frames": "sheet", "notification-frames": "notification"}.get(name)})
    out.append({"name": "gpu-contracts", "kind": "probe", "exe_name": GPU_PROBE, "blocking": True})
    if include_a11y:
        for suite in sorted((REPO / "e2e").glob("windows-accessibility*.test.ts")):
            short = suite.name.removeprefix("windows-").removesuffix(".test.ts")
            # The original UIA suite exercises Gallery controls; the widget
            # suites exercise Storybook. Keep each suite with its fixture app.
            app = "render-gallery" if suite.name == "windows-accessibility.test.ts" else "storybook"
            out.append({"name": short, "kind": "e2e", "exe_name": queue.E2E_APPS[app],
                        "suite_source": f"e2e/{suite.name}", "minimum_cases": 1, "blocking": False, "filter": ""})
    return out


def build(arch: str, prefix: Path) -> None:
    common = [f"-Dwindows-arch={arch}", "--prefix", str(prefix)]
    subprocess.run(["zig", "build", "windows-arm64-storybook", "windows-arm64-text-input", "windows-arm64-render-gallery",
                    "-Dtest-mode=true", "-Dgpu-backend=d3d12", "-Doptimize=fast", *common], cwd=REPO, check=True)
    subprocess.run(["zig", "build", "windows-arm64-gpu-resources-contract", "-Doptimize=fast",
                    "-Dwindows-gpu-contract-scope=all", *common], cwd=REPO, check=True)


def bundle_suite(suite: str, outfile: Path) -> None:
    entry = REPO / "e2e" / f".windows-batch-entry-{uuid.uuid4().hex}.ts"
    # Imports evaluate in order: the preflight (startup, renderer checks) completes before the suite.
    entry.write_text(f'import "./windows-renderer-preflight.ts";\nimport "./{Path(suite).name}";\n')
    try:
        subprocess.run(["bun", "build", "--target=bun", "--sourcemap=inline", str(entry), "--outfile", str(outfile)],
                       cwd=REPO, check=True, stdout=subprocess.DEVNULL)
    finally:
        entry.unlink(missing_ok=True)


def suite_runtime(scratch: Path) -> Path:
    version = subprocess.run(["bun", "--version"], check=True, capture_output=True, text=True).stdout.strip()
    # Baseline (no AVX2): Windows on Arm's x64 emulation lacks AVX2.
    runtime = Path.home() / ".bun/install/cache" / f"bun-windows-x64-baseline-v{version}"
    if not runtime.is_file():
        entry = REPO / "e2e" / "windows-renderer-preflight.ts"
        subprocess.run(["bun", "build", "--compile", "--target=bun-windows-x64-baseline", str(entry),
                        "--outfile", str(scratch / "runtime-fetch.exe")], cwd=REPO, check=True, stdout=subprocess.DEVNULL)
        (scratch / "runtime-fetch.exe").unlink(missing_ok=True)
    queue.require_pe_arch(runtime, "x86_64")
    return runtime


def make_job(plan: list[dict], bin_dir: Path, arch: str, folder: Path, startup_timeout: float) -> str:
    """Write zenit-batch.zip + zenit-bun.exe into the job folder; return the runtime digest."""
    scratch = Path(tempfile.mkdtemp(prefix="zenit-batch-"))
    manifest = {"stages": []}
    with zipfile.ZipFile(folder / queue.BATCH_BUNDLE, "w", zipfile.ZIP_DEFLATED) as bundle:
        for exe_name in sorted({stage["exe_name"] for stage in plan}):
            exe = bin_dir / exe_name
            queue.require_pe_arch(exe, arch)
            bundle.write(exe, exe_name)
        for stage in plan:
            entry = {key: stage.get(key) for key in ("name", "kind", "exe_name", "capture_frames", "trace_frames")}
            if stage["kind"] == "e2e":
                js = scratch / f"{stage['name']}.js"
                bundle_suite(stage["suite_source"], js)
                bundle.write(js, f"suites/{stage['name']}.js")
                entry["suite"] = f"suites/{stage['name']}.js"
                entry["env"] = {"ZENIT_E2E_TIMEOUT_MS": "40000", "ZENIT_E2E_EXPECT_RENDERER": "d3d12",
                                "ZENIT_E2E_STARTUP_TIMEOUT_MS": str(round(startup_timeout * 1000))}
                if stage["filter"]:
                    entry["env"]["ZENIT_E2E_FILTER"] = stage["filter"]
            manifest["stages"].append(entry)
        bundle.writestr("manifest.json", json.dumps(manifest, indent=2))
    shutil.copy2(suite_runtime(scratch), folder / queue.LOCAL_SUITE_RUNTIME)
    shutil.rmtree(scratch, ignore_errors=True)
    (folder / "batch-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    return hashlib.sha256((folder / queue.LOCAL_SUITE_RUNTIME).read_bytes()).hexdigest()


def extract(archive: Path, target: Path) -> None:
    target = target.resolve()
    with zipfile.ZipFile(archive) as z:
        # .NET Framework's ZipFile writes Windows separators into names.
        for info in z.infolist():
            destination = (target / info.filename.replace("\\", "/")).resolve()
            if target not in destination.parents or info.is_dir():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(z.read(info))


def suite_summary(stage_dir: Path) -> dict | None:
    session = stage_dir / "windows-suite-session.zip"
    if not session.is_file():
        return None
    extract(session, stage_dir / "session")
    found = list((stage_dir / "session").rglob("summary.json"))
    return json.loads(found[0].read_text()) if len(found) == 1 else None


def judge(stage: dict, stage_dir: Path) -> tuple[bool, str]:
    if not stage_dir.is_dir():
        return False, "no evidence returned"
    result = json.loads((stage_dir / "stage-result.json").read_text(encoding="utf-8-sig"))
    error = (result.get("error") or "").strip()
    if error:
        return False, f"stage error (exit {result['exit_code']}): {error[:300]}"
    if stage["kind"] == "probe":
        try:
            queue.validate_gpu_scope(stage_dir, "all")
        except ValueError as error:
            return False, str(error)
        passes = len(re.findall(r"^PASS:", (stage_dir / "windows-probe-stderr.log").read_text(errors="replace"), re.MULTILINE))
        errors = re.findall(r"^error: .*$", (stage_dir / "windows-probe-stderr.log").read_text(errors="replace"), re.MULTILINE)
        ok = result["exit_code"] == 0
        return ok, f"{passes} contract PASS" + ("" if ok else f"; {'; '.join(errors) or result.get('error', '').strip()}")
    summary = suite_summary(stage_dir)
    if summary is None:
        return False, f"no suite summary (exit {result['exit_code']}): {result.get('error', '').strip()[:300]}"
    text = f"{summary['passed']}/{summary['total']} passed"
    failures = [f"{f.get('name')}: {f.get('error', '')}"[:240] for f in summary.get("failures", [])]
    ok = (result["exit_code"] == 0 and summary["total"] >= stage["minimum_cases"] and summary["executed"] == summary["total"]
          and summary["passed"] == summary["total"] and not summary["failed"] and not summary["aborted"])
    audit = stage.get("audit")
    if ok and audit:
        command = ([sys.executable, str(REPO / "tools/windows_modal_frame_audit.py"), str(stage_dir), "--allow-shadow-halo"] if audit == "modal"
                   else [sys.executable, str(REPO / f"tools/windows_shared_{audit}_frame_audit.py"), str(stage_dir)])
        run = subprocess.run(command, capture_output=True, text=True, timeout=300)
        (stage_dir / f"host-{audit}-audit.log").write_text(run.stdout + run.stderr)
        verdict = stage_dir / f"{audit}-frame-audit.json"
        passed = run.returncode == 0 and (audit == "modal" or json.loads(verdict.read_text()).get("passed") is True)
        text += f"; {audit} frame audit {'passed' if passed else 'FAILED'}"
        if not passed:
            ok = False
            failures.append((run.stdout + run.stderr).strip()[-300:])
    return ok, text + ("" if not failures else " | " + " | ".join(failures))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="http://127.0.0.1:19817")
    parser.add_argument("--arch", choices=["aarch64", "x86_64"], default="aarch64")
    parser.add_argument("--artifact-dir", type=Path, help="prebuilt bin directory (default: build into an isolated prefix)")
    parser.add_argument("--skip-build", action="store_true", help="reuse --artifact-dir (or zig-out/bin) as is")
    parser.add_argument("--prepare-only", action="store_true", help="bundle all artifacts without contacting a worker")
    parser.add_argument("--output-dir", type=Path, help="bundle directory for --prepare-only")
    parser.add_argument("--require-a11y", action="store_true", help="fail the batch if any UI Automation suite fails")
    parser.add_argument("--no-a11y", action="store_true", help="skip the UI Automation suites")
    parser.add_argument("--startup-timeout", type=float, default=60)
    parser.add_argument("--timeout", type=float, default=3600, help="seconds for the whole batch on the worker")
    args = parser.parse_args()
    if args.prepare_only and args.output_dir is None:
        parser.error("--prepare-only requires --output-dir")
    if args.require_a11y and args.no_a11y:
        parser.error("--require-a11y conflicts with --no-a11y")
    root = queue.data_dir()
    base = args.base.rstrip("/")
    started = time.monotonic()
    bin_dir = args.artifact_dir or REPO / "zig-out/bin"
    if not args.skip_build:
        prefix = Path(tempfile.mkdtemp(prefix=f"zenit-win-{args.arch}-"))
        print(f"==> Building {args.arch} apps and GPU contracts into {prefix}", flush=True)
        build(args.arch, prefix)
        bin_dir = prefix / "bin"
    plan = stages(not args.no_a11y)
    if args.require_a11y:
        for stage in plan:
            stage["blocking"] = True
    job_id = uuid.uuid4().hex
    folder = args.output_dir if args.prepare_only else root / "jobs" / job_id
    folder.mkdir(parents=True, exist_ok=args.prepare_only)
    print(f"==> Bundling {len(plan)} stages", flush=True)
    runtime_sha = make_job(plan, bin_dir, args.arch, folder, args.startup_timeout)
    size = (folder / queue.BATCH_BUNDLE).stat().st_size
    if args.prepare_only:
        print(f"==> Prepared {len(plan)} stages ({size / 1e6:.1f} MB bundle); {folder}", flush=True)
        return 0
    token = queue.read_token(root)
    queue.require_worker(queue.request(base, token, "GET", "/health"))
    queue.request(base, token, "POST", "/jobs", {"id": job_id, "kind": "batch", "local_suite": {"env": {}, "runtime_sha256": runtime_sha}})
    print(f"==> Batch job {job_id} queued ({size / 1e6:.1f} MB bundle); evidence: {folder}", flush=True)
    deadline = time.monotonic() + args.timeout
    last = ""
    while time.monotonic() < deadline:
        state = queue.request(base, token, "GET", f"/jobs/{job_id}")
        if state["status"] != last:
            print(f"    worker: {state['status']} (+{time.monotonic() - started:.0f}s)", flush=True)
            last = state["status"]
        if state["status"] in {"passed", "failed"}:
            break
        time.sleep(2)
    else:
        print(f"TIMEOUT: the batch did not finish in {args.timeout:.0f}s; {folder}", file=sys.stderr)
        return 1
    if state.get("error"):
        print(f"    worker note: {state['error'].strip()[:400]}")
    report = []
    for stage in plan:
        stage_dir = folder / "stages" / stage["name"]
        archive = folder / f"batch-{stage['name']}.zip"
        if archive.is_file():
            extract(archive, stage_dir)
        ok, detail = judge(stage, stage_dir)
        report.append({"stage": stage["name"], "blocking": stage["blocking"], "passed": ok, "detail": detail})
        mark = "PASS" if ok else ("FAIL" if stage["blocking"] else "fail (reported)")
        print(f"  {mark:16} {stage['name']:22} {detail}", flush=True)
    (folder / "batch-report.json").write_text(json.dumps(report, indent=2) + "\n")
    blocking_failed = [r["stage"] for r in report if r["blocking"] and not r["passed"]]
    # Passing stage evidence does not override a failed batch finalization.
    passed = state["status"] == "passed" and not blocking_failed
    failures = blocking_failed + ([] if state["status"] == "passed" else ["batch finalization"])
    print(f"==> {'PASSED' if passed else 'FAILED: ' + ', '.join(failures)} "
          f"in {time.monotonic() - started:.0f}s; report {folder / 'batch-report.json'}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

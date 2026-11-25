#!/usr/bin/env python3
"""Offline unit tests for tools/eos-progress.py Android 17 siso executor & ETA tracking."""
import importlib.util
import os
import tempfile
import time
import unittest

TOOLS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT_DIR = os.path.dirname(TOOLS_DIR)
EOS_PROGRESS = os.path.join(TOOLS_DIR, "eos-progress.py")


def _encode_varint(val: int) -> bytes:
    out = bytearray()
    while True:
        b = val & 0x7F
        val >>= 7
        if val:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _encode_build_progress(total: int, done: int, running: int, failed: int = 0) -> bytes:
    # BuildProgress protobuf: 1=total_actions, 2=finished_actions, 3=current_actions, 4=failed_actions
    return (
        _encode_varint((1 << 3) | 0) + _encode_varint(total)
        + _encode_varint((2 << 3) | 0) + _encode_varint(done)
        + _encode_varint((3 << 3) | 0) + _encode_varint(running)
        + _encode_varint((4 << 3) | 0) + _encode_varint(failed)
    )


def _load_progress_module(top: str, jobs: str, times: str):
    os.environ["EOS_TOP"] = top
    os.environ["EOS_JOBS"] = jobs
    os.environ["EOS_KIT"] = KIT_DIR
    os.environ["EOS_TIMES"] = times
    spec = importlib.util.spec_from_file_location("eos_progress", EOS_PROGRESS)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class EosProgressSisoTest(unittest.TestCase):
    def _write_log(self, path: str, now: float):
        t0 = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 600))
        t1 = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 580))
        lines = [
            f"STEP prepare device=kodiak kind=full fresh=0 at={t0}\n",
            f"STEP make device=kodiak kind=full fresh=0 at={t1}\n",
            "[ 25% 30000/120000] //frameworks/base:services javac\n",
        ]
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.utime(path, (now - 2, now - 2))

    def test_siso_combined_ninja_uses_rate_eta_basis(self):
        with tempfile.TemporaryDirectory() as tmp:
            top = os.path.realpath(os.path.join(tmp, "tree"))
            jobs = os.path.join(tmp, "jobs")
            times = os.path.join(tmp, "times.txt")
            os.makedirs(os.path.join(top, "out"), exist_ok=True)
            os.makedirs(jobs, exist_ok=True)
            open(times, "w", encoding="utf-8").close()

            mod = _load_progress_module(top, jobs, times)
            now = mod.NOW
            log = os.path.join(tmp, "build-kodiak.log")
            self._write_log(log, now)
            pb = os.path.join(top, "out", "build_progress.pb")
            with open(pb, "wb") as f:
                f.write(_encode_build_progress(total=120000, done=30000, running=16))
            os.utime(pb, (now - 1, now - 1))

            procs = [
                (1001, now - 580, [f"{top}/out/soong_ui", "--build-mode", "--all-modules", "-j16", "eos"], top),
                (
                    1002,
                    now - 500,
                    [
                        "prebuilts/siso/linux-x86/siso",
                        "ninja",
                        "--frontend_file",
                        "out/.ninja_fifo",
                        "eos",
                        "-f",
                        "out/combined-eos_kodiak.ninja",
                    ],
                    top,
                ),
            ]
            run = mod.Run("-", log, None, True, "kodiak")
            run.finish(procs)
            run.eta()
            p = run.phones["kodiak"]
            self.assertIsNotNone(run.ninja_start)
            self.assertEqual(p.counts["done"], 30000)
            self.assertEqual(p.counts["total"], 120000)
            self.assertEqual(p.basis, "rate")
            # 30k done in 500s => 90k remaining takes ~1500s + tail (300s) + verify (100s) + pack (100s) = ~2000s (not 790s typical)
            self.assertGreater(p.eta - now, 1800)

    def test_siso_bootstrap_graph_does_not_set_ninja_start_and_orphaned_siso_keeps_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            top = os.path.realpath(os.path.join(tmp, "tree"))
            jobs = os.path.join(tmp, "jobs")
            times = os.path.join(tmp, "times.txt")
            os.makedirs(os.path.join(top, "out"), exist_ok=True)
            os.makedirs(jobs, exist_ok=True)
            open(times, "w", encoding="utf-8").close()

            mod = _load_progress_module(top, jobs, times)
            now = mod.NOW
            log = os.path.join(tmp, "build-kodiak.log")
            self._write_log(log, now)
            pb = os.path.join(top, "out", "build_progress.pb")
            with open(pb, "wb") as f:
                f.write(_encode_build_progress(total=120000, done=24000, running=8))
            os.utime(pb, (now - 1, now - 1))

            # Bootstrap siso (out/soong/build.eos_kodiak.ninja) is Soong analysis, not combined-<product>.ninja
            bootstrap_procs = [
                (1001, now - 580, [f"{top}/out/soong_ui", "--build-mode", "eos"], top),
                (1002, now - 560, ["prebuilts/siso/linux-x86/siso", "ninja", "-f", "out/soong/bootstrap.ninja", "out/soong/build.eos_kodiak.ninja"], top),
            ]
            run_boot = mod.Run("-", log, None, True, "kodiak")
            run_boot.finish(bootstrap_procs)
            self.assertIsNone(run_boot.ninja_start)

            # Orphaned main siso (soong_ui gone, combined-eos_kodiak.ninja siso still alive) still tracks counts & rate
            orphan_procs = [
                (1003, now - 400, ["prebuilts/siso/linux-x86/siso", "ninja", "-f", "out/combined-eos_kodiak.ninja"], top),
            ]
            run_orphan = mod.Run("-", log, None, True, "kodiak")
            run_orphan.finish(orphan_procs)
            run_orphan.eta()
            p_orphan = run_orphan.phones["kodiak"]
            self.assertEqual(p_orphan.counts["done"], 24000)
            self.assertEqual(p_orphan.basis, "rate")


if __name__ == "__main__":
    unittest.main()

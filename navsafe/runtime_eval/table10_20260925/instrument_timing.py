#!/usr/bin/env python3
"""Add measurement-only per-frame latency logging to a pinned checkout."""
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old = """        while True:
            keep_going = self._step()
            if not keep_going:
                break
"""
new = """        while True:
            _frame_t0 = _time.perf_counter()
            keep_going = self._step()
            _frame_dt = _time.perf_counter() - _frame_t0
            if not hasattr(self, \"_prof_samples\"):
                self._prof_samples = _defaultdict(list)
            self._prof_samples[\"e2e_frame\"].append(_frame_dt)
            if not keep_going:
                break
"""
assert old in s
s = s.replace(old, new, 1)

old = """            sys.stderr.flush()
        return results
"""
new = """            if hasattr(self, \"_prof_samples\"):
                import numpy as _np
                for _k, _xs in sorted(self._prof_samples.items()):
                    if not _xs:
                        continue
                    _a = _np.asarray(_xs, dtype=float) * 1000.0
                    sys.stderr.write(
                        f\"[PROFILE_DIST] {_k} n={len(_a)} \"
                        f\"p50_ms={_np.percentile(_a, 50):.3f} \"
                        f\"p95_ms={_np.percentile(_a, 95):.3f} \"
                        f\"max_ms={_a.max():.3f}\\n\")
            sys.stderr.flush()
        return results
"""
assert old in s
s = s.replace(old, new, 1)

old = """        self._prof[key] += _time.perf_counter() - t0
"""
new = """        _dt = _time.perf_counter() - t0
        self._prof[key] += _dt
        if not hasattr(self, \"_prof_samples\"):
            self._prof_samples = _defaultdict(list)
        self._prof_samples[key].append(_dt)
"""
assert old in s
s = s.replace(old, new, 1)

old = """        model_input = self.adapter.prepare_input(
"""
new = """        _policy_t0 = _time.perf_counter()
        model_input = self.adapter.prepare_input(
"""
assert old in s
s = s.replace(old, new, 1)

old = """        parsed = self.adapter.parse_output(raw_output, ego_state)
"""
new = """        parsed = self.adapter.parse_output(raw_output, ego_state)
        self._prof_add('policy', _policy_t0)
"""
assert old in s
s = s.replace(old, new, 1)

p.write_text(s)
print(f"instrumented {p}")

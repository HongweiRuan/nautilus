from pathlib import Path
import sys
src, dst = map(Path, sys.argv[1:])
text = src.read_text()
def sub(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit(f"expected exactly one {old!r} in {src}, found {text.count(old)}")
    text = text.replace(old, new)
# controller + Robin's adapter/agent setup (as in codex's job-hazard-best-*.yaml)
sub('--controller lqr --execution-mode controller', '--controller "$CONTROLLER" --execution-mode controller')
sub('[ -f "$INC/Python.h" ] || { say "missing Python.h under $INC"; exit 1; }\n',
    '[ -f "$INC/Python.h" ] || { say "missing Python.h under $INC"; exit 1; }\nsource /avl-west/navsafe_eval/robin_proxy_eval/robin_setup.sh\n')
# plain eval: one renderer per worker, reused across cells; restarted only if it died (like the proxy/leaderboard worker)
sub('      start_renderer || exit 1\n',
    '      if ! { [ -n "${SERVE_PID:-}" ] && kill -0 "$SERVE_PID" 2>/dev/null && (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; }; then\n'
    '        say "renderer not running; starting it"; start_renderer || exit 1\n'
    '      fi\n')
sub("say 'renderer ready (fresh cell isolation)'", "say 'renderer ready (one renderer per worker, reused across cells)'")
# plain eval: no reactivity trace, and no trace audit in the resume / success checks
sub('          --record-reactivity-trace --reactivity-condition hazard --reactivity-group-id "$LEAF/$TOKEN/$EVENT" \\\n', '')
sub(' && "$PY" "$CAMPAIGN_ROOT/audit_trace.py" "$TRACE" >/dev/null; then', '; then')
sub(' && "$PY" "$CAMPAIGN_ROOT/audit_trace.py" "$TRACE" > "$OUT/reactivity_trace_audit.json"; then', '; then')
dst.write_text(text); dst.chmod(0o755)
print("patched", dst)

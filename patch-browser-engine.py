#!/usr/bin/env python3
"""Keep Hermes from handing Chromium-only launch flags to Lightpanda.

WHY
---
``tools/browser_tool.py`` injects

    AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage"

whenever it runs as root (or on an AppArmor userns-restricted host) — the
``_needs_sandbox_bypass`` block. Those are Chromium launch flags.

With ``browser.engine: lightpanda``, agent-browser forwards them to Lightpanda,
which rejects them:

    {"error":"Custom Chrome arguments (--args) are not supported with Lightpanda",
     "success":false}

Failure chain observed live (2026-10-31):
  * ``open`` fails -> Hermes triggers its Chrome fallback -> with no Chromium it
    dies with "Chrome fallback failed: could not determine current URL";
  * and even *with* Chromium, the fallback's own URL probe re-runs ``eval`` with
    ``_engine_override="auto"``. That "auto" call talks to the **existing
    Lightpanda daemon** (agent-browser locks the engine per session) — so unless
    the guard also looks at the *configured* engine, the same Chromium flags get
    injected again and the probe fails identically:
        EVAL auto: {"error":"Custom Chrome arguments (--args) are not supported
                    with Lightpanda","success":false}

Hence the injection must be skipped whenever the session's real engine is
Lightpanda — which is true when *either* the per-call override *or* the
configured engine is ``lightpanda``.

Idempotent and upgrade-aware. Handles three on-disk states and fails the *image
build* loudly if upstream rewrites the block (same philosophy as the Lightpanda
CDP smoke-test in the Dockerfile) rather than silently shipping a broken browser
stack.

Usage: patch-browser-engine.py [path]   (default /opt/hermes-agent/tools/browser_tool.py)
"""
from __future__ import annotations

import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "/opt/hermes-agent/tools/browser_tool.py"

# State A — pristine upstream.
STATE_A = '''        if (
            "AGENT_BROWSER_ARGS" not in browser_env
            and "AGENT_BROWSER_CHROME_FLAGS" not in browser_env
        ):'''

# State B — first-generation patch (override only). Insufficient: the "auto"
# fallback probe still reached a Lightpanda daemon and got the Chrome flags.
STATE_B = '''        if (
            "AGENT_BROWSER_ARGS" not in browser_env
            and "AGENT_BROWSER_CHROME_FLAGS" not in browser_env
            and engine != "lightpanda"
        ):'''

# State C — correct. Checks both the override and the configured engine.
STATE_C = '''        if (
            "AGENT_BROWSER_ARGS" not in browser_env
            and "AGENT_BROWSER_CHROME_FLAGS" not in browser_env
            and engine != "lightpanda"
            and _get_browser_engine() != "lightpanda"
        ):'''


def main() -> int:
    try:
        src = open(PATH, encoding="utf-8").read()
    except OSError as e:
        print(f"patch-browser-engine: cannot read {PATH}: {e}", file=sys.stderr)
        return 1

    if STATE_C in src:
        print("patch-browser-engine: up to date (state C) — nothing to do")
        return 0

    if src.count(STATE_A) == 1:
        src = src.replace(STATE_A, STATE_C, 1)
        note = "A -> C (pristine)"
    elif src.count(STATE_B) == 1:
        src = src.replace(STATE_B, STATE_C, 1)
        note = "B -> C (upgraded incomplete patch)"
    else:
        print(
            "patch-browser-engine: FAILED — found neither the pristine nor the "
            f"intermediate injection guard (A={src.count(STATE_A)}, "
            f"B={src.count(STATE_B)}). Upstream browser_tool.py changed; "
            "re-inspect the _needs_sandbox_bypass block and update this patch.",
            file=sys.stderr,
        )
        return 1

    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(src)

    if STATE_C not in open(PATH, encoding="utf-8").read():
        print("patch-browser-engine: FAILED — write verification failed", file=sys.stderr)
        return 1

    print(f"patch-browser-engine: applied ({note}) — Lightpanda never gets Chromium flags")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

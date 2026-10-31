#!/usr/bin/env python3
"""Make Hermes' Chromium sandbox-flag injection engine-aware.

WHY
---
tools/browser_tool.py injects

    AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage"

whenever it runs as root (or on an AppArmor userns-restricted host) — see the
``_needs_sandbox_bypass`` block. Those are Chromium launch flags.

With ``browser.engine: lightpanda``, agent-browser forwards them to Lightpanda,
which rejects them outright:

    {"error":"Custom Chrome arguments (--args) are not supported with Lightpanda",
     "success":false}

So *every* browser command "fails", Hermes starts its Chrome fallback, and with
no Chromium path available it surfaces:

    Chrome fallback failed: could not determine current URL

...even though ``agent-browser --engine lightpanda open <url>`` works perfectly
by hand. (Verified 2026-10-31 in the live container.)

FIX
---
Add ``and engine != "lightpanda"`` to the injection guard: Lightpanda sessions
never receive Chromium-only flags; chrome / Chrome-for-Testing sessions keep
their ``--no-sandbox`` behaviour unchanged.

Idempotent — re-running on an already-patched file is a no-op. Exits 1 if the
expected block is absent, so a HERMES_REF bump that rewrites the block fails the
*image build* loudly instead of silently shipping a broken browser stack (same
philosophy as the Lightpanda CDP smoke-test in the Dockerfile).
"""
from __future__ import annotations

import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "/opt/hermes-agent/tools/browser_tool.py"

OLD = '''        if (
            "AGENT_BROWSER_ARGS" not in browser_env
            and "AGENT_BROWSER_CHROME_FLAGS" not in browser_env
        ):'''

NEW = '''        if (
            "AGENT_BROWSER_ARGS" not in browser_env
            and "AGENT_BROWSER_CHROME_FLAGS" not in browser_env
            and engine != "lightpanda"
        ):'''


def main() -> int:
    try:
        src = open(PATH, encoding="utf-8").read()
    except OSError as e:
        print(f"patch-browser-engine: cannot read {PATH}: {e}", file=sys.stderr)
        return 1

    if NEW in src:
        print("patch-browser-engine: already applied — nothing to do")
        return 0

    found = src.count(OLD)
    if found != 1:
        print(
            f"patch-browser-engine: FAILED — expected exactly 1 match of the "
            f"injection guard, found {found}. Upstream browser_tool.py changed; "
            f"re-inspect the _needs_sandbox_bypass block and update this patch.",
            file=sys.stderr,
        )
        return 1

    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(src.replace(OLD, NEW, 1))

    if NEW not in open(PATH, encoding="utf-8").read():
        print("patch-browser-engine: FAILED — write verification failed", file=sys.stderr)
        return 1

    print("patch-browser-engine: applied (lightpanda no longer gets Chromium flags)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# Python 3.14 is REQUIRED, not cosmetic. Every direct dependency in hermes-agent
# v0.22.5's pyproject.toml carries a `python_version >= '3.14'` marker (46 of 47;
# only uvloop is unguarded). On 3.12/3.13 `uv pip install` therefore resolves to
# an EMPTY runtime dependency set: no openai, no ruamel, no rich — the `hermes`
# CLI dies on `import ruamel` and only a stubbed `--version` still answers.
# Verified live: v0.22.5 on 3.12 → broken CLI; on 3.14 → full CLI + imports OK.
FROM ghcr.io/astral-sh/uv:python3.14-bookworm-slim

# Which hermes-agent revision to install. Accepts any git ref the upstream
# repo publishes — a release tag (recommended for reproducibility) or a
# branch name (`main`) for bleeding edge.
#
# To bump: check https://github.com/NousResearch/hermes-agent/releases for the
# newest tag and update the default below. NOTE: upstream changed the tag scheme
# — releases up to ~2026.09 used `vYYYY.M.D` (e.g. v2026.9.24), the current
# series is `v0.NN.N` (e.g. v0.22.5). Do not sort the two schemes against each
# other as strings; check the release page for what is actually newest.
# Use `main` only if you accept that every rebuild can pull arbitrary new
# upstream commits.
ARG HERMES_REF=v0.22.5

# tini = tiny init that we run as PID 1. Without it, hermes's grandchild
# processes (MCP stdio servers, git, bun, browser daemons spawned by tools)
# reparent to PID 1 when their parents exit and pile up as zombies. After
# weeks of uptime that exhausts the kernel's PID table → "fork: cannot
# allocate memory" and the container dies. tini reaps zombies in the
# background and forwards SIGTERM/SIGINT to our entrypoint so Railway's
# stop signal still triggers our graceful shutdown. Standard container init
# (same as Docker's `--init` flag and Kubernetes' pause container).
#
# Node.js is required only at build time to compile the Hermes React dashboard.
# We strip the source + apt lists afterwards to keep the image lean.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl ca-certificates git tini ffmpeg libopus0 \
        chromium fonts-liberation \
        procps xz-utils libatomic1 \
        gcc g++ make cmake pkg-config libffi-dev && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*
# procps/xz-utils/libatomic1 are runtime (upstream's image ships them too; a
# container without `ps` is painful to debug). The compiler toolchain
# (gcc g++ make cmake pkg-config libffi-dev) is only needed so `uv pip install`
# can build any sdist that has no manylinux wheel — it is purged again after the
# Hermes install below, so it never reaches the shipped layer's final state.

# --- Chromium: vollständige Browser-Engine für Screenshots und Fallback ------
# Lightpanda (unten) ist schnell und genügsam, kann aber NICHT screenshotten und
# scheitert an JS-lastigen Seiten. Chromium ist die vollwertige Engine:
#   * agent-browser --engine chrome  -> echte Screenshots, volles DOM
#   * Hermes' automatischer Lightpanda->Chrome-Fallback braucht eine Chromium-
#     Installation, sonst endet jeder Fallback in
#     "Chrome fallback failed: could not determine current URL".
# apt-chromium (~348 MB in /usr/lib/chromium) liegt IM Image und überlebt damit
# jeden Volume-Wipe — anders als `agent-browser install`, das ~650 MB Chrome for
# Testing ins Volume /data lädt und dort beim Aufräumen verschwindet.
# Als root braucht Chromium --no-sandbox; das injiziert Hermes selbst (siehe
# patch-browser-engine.py weiter unten).


# --- Browser-Automation ohne Chromium-Ballast -------------------------------
# Hermes' Browser-Toolset spricht die CLI `agent-browser` an. Standard-Engine ist
# Chrome (Chrome for Testing) -> beim ersten Gebrauch ~650 MB Download, landet im
# Volume /data (wird mitberechnet und ist nach jedem Volume-Aufräumen weg).
# Statt dessen: Lightpanda als Engine (browser.engine: lightpanda in config.yaml).
# Lightpanda ist EIN Binary (~75 MB, Zig, CDP-kompatibel), gemessen 14 MB RSS im
# Leerlauf vs. mehrere hundert MB bei Chrome. Kein Screenshot-Support — dafür
# fällt Hermes bei Befehlen, die Lightpanda nicht kann, selbst auf Chrome zurück.
#
# ACHTUNG Nightly-Drift: der Release-Tag `nightly` wird täglich überschrieben.
# Argument-Änderungen brechen den Shim (vgl. lightpanda-shim.sh). Der Build
# prüft das per Smoke-Test unten und schlägt dann LAUT fehl statt still kaputt.
# Fallback auf eine feste Version: LIGHTPANDA_TAG=v0.2.6 setzen (v0.2.6 hat
# noch das alte CLI mit --timeout, kommt also ohne Shim aus — ältere Website-
# Kompatibilität).
ARG LIGHTPANDA_TAG=nightly
RUN npm install -g agent-browser && \
    mkdir -p /opt/lightpanda && \
    curl -fsSL -o /opt/lightpanda/lightpanda \
      "https://github.com/lightpanda-io/browser/releases/download/${LIGHTPANDA_TAG}/lightpanda-x86_64-linux" && \
    chmod +x /opt/lightpanda/lightpanda
COPY lightpanda-shim.sh /usr/local/bin/lightpanda
RUN chmod +x /usr/local/bin/lightpanda && \
    lightpanda version && \
    agent-browser --version && \
    ( lightpanda serve --port 9222 --timeout 15000 & \
      LP_PID=$!; \
      sleep 3; \
      curl -fsS http://127.0.0.1:9222/json/version > /dev/null || \
        { echo "LIGHTPANDA/CDP-SMOKE-TEST FEHLGESCHLAGEN — Shim vs. Lightpanda-Argumente prüfen"; kill $LP_PID; exit 1; }; \
      kill $LP_PID )

# Install hermes-agent (provides the `hermes` CLI) and pre-build its React
# dashboard so `hermes dashboard` has nothing to build at runtime.
#
# Extras MUST be re-checked on every HERMES_REF bump — upstream retires them and
# a stale name makes `uv pip install` fail outright. For v0.22.5:
#   * `all` = cron, pty, mcp, uvloop, sms, acp, google, web, youtube
#   * `honcho` and `hindsight` were REMOVED upstream (honcho moved into its own
#     plugin) — they are deliberately no longer in the list below.
# Messaging platforms, TTS and other heavy backends are lazy-installed by hermes
# at first use. We pre-install the ones this template actually uses so
# first-message latency is instant.
# INSTALL MODEL — locked, not freshly resolved.
# Upstream ships a `uv.lock` (1.2 MB, exact-pinned) and expects installs to go
# through it (`hermes pm lock`). A fresh resolve of `-e ".[all,...]"` is
# UNSATISFIABLE on v0.22.5:
#     browser-harness==0.1.13  pins pillow==12.3.0
#     hermes-agent (base)      pins pillow==13.0.0
#   -> `uv pip install -e ".[all,...]"` aborts with "No solution found".
# (The very same extras resolve fine through the lock — proven both ways.)
# So: `uv export` renders the lock to exact-pinned requirements, we install those
# into the system interpreter, then add hermes itself editable with --no-deps so
# /opt/hermes-agent stays the live source tree (needed for HERMES_TUI_DIR and the
# pre-built hermes_cli/web_dist).
# Verified locally against v0.22.5 on Python 3.14: export -> 423 pinned lines,
# deps install rc=0, editable install rc=0, `hermes --version` -> v0.22.5,
# `import hermes_cli.main / tools.browser_tool / gateway.run` all OK.
RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv export --frozen --no-emit-project --no-hashes \
        --extra all --extra messaging --extra tts-premium \
        --extra bedrock --extra anthropic --extra edge-tts \
        -o /tmp/hermes-reqs.txt && \
    uv pip install --system --no-cache -r /tmp/hermes-reqs.txt && \
    uv pip install --system --no-cache --no-deps -e . && \
    printf 'docker\n' > /opt/hermes-agent/.install_method && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm /tmp/hermes-reqs.txt

# --- Browser: Chromium-Flag-Patch entfällt ab v0.22.5 ------------------------
# Hermes ≤0.14 injizierte als root automatisch
#   AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage"
# (tools/browser_tool.py, _needs_sandbox_bypass). Das sind Chrome-Flags und
# Lightpanda lehnt sie ab ("Custom Chrome arguments (--args) are not supported
# with Lightpanda") — jeder Browser-Befehl scheiterte. patch-browser-engine.py
# hat das geradegezogen.
#
# v0.22.5 hat den Browser-Stack neu gebaut: browser_tool.py schrumpfte von 3676
# auf ~1376 Zeilen, die Fallback-Logik zog in tools/browser_tool_lightpanda_fallback
# um, und die Injection ist ersatzlos verschwunden. Der Patch hätte keinen Anker
# mehr und würde den Build ABSICHTLICH sprengen (sein Design). Darum ist der
# Schritt hier entfernt. Das Skript bleibt im Repo, falls je auf einen ≤0.14-Zweig
# zurückgegangen wird.

# Why pre-build ui-tui (and why we don't delete it after):
# - The dashboard's embedded Chat tab spawns `node ui-tui/dist/entry.js`
#   on every WebSocket connect to /api/pty.
# - Without HERMES_TUI_DIR, hermes's _make_tui_argv falls through to the
#   npm install + build path (since git-editable installs don't have the
#   bundled tui_dist/ that PyPI wheels include), adding 30-60s to the
#   first chat-open and blocking the asyncio event loop.
# - Pre-building at image time surfaces build failures here rather than
#   at user request time, and makes first-chat-open instant.
# - We keep ui-tui/ entirely (node_modules + dist + src) so HERMES_TUI_DIR
#   can point at it (see below).

COPY requirements.txt /app/requirements.txt
RUN uv pip install --system --no-cache -r /app/requirements.txt

# faster-whisper für lokale STT (Speech-to-Text) — wird von Hermes für
# Sprachnachrichten-Transkription verwendet, wenn stt.provider=local
RUN uv pip install --system --no-cache faster-whisper

# Drop the compile-only toolchain — must come AFTER every pip install, since any
# of them can still pull an sdist that needs building. Only the compilers are
# purged (no --auto-remove) so nothing runtime-relevant (libffi8, libatomic1,
# procps) gets swept along by dependency resolution.
RUN apt-get purge -y gcc g++ make cmake pkg-config libffi-dev && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /data/.hermes

COPY server.py /app/server.py
COPY templates/ /app/templates/
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes

# Points hermes at our pre-built TUI bundle. hermes's _make_tui_argv checks
# HERMES_TUI_DIR first: if dist/entry.js exists there, it skips the npm
# install/build entirely. This is the official packager path (Nix uses it too)
# and avoids the 30-60s npm bootstrap that git-editable installs would otherwise
# trigger on first /chat connection.
ENV HERMES_TUI_DIR=/opt/hermes-agent/ui-tui

# tini wraps start.sh so it runs as PID 1's child instead of as PID 1 itself.
# `-g` propagates signals to the whole process group so `docker stop` /
# Railway's SIGTERM cleanly terminates the entire tree, not just start.sh.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]

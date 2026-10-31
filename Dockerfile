FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Which hermes-agent revision to install. Accepts any git ref the upstream
# repo publishes — a release tag (recommended for reproducibility) or a
# branch name (`main`) for bleeding edge.
#
# To bump: check https://github.com/NousResearch/hermes-agent/releases for the
# newest tag (format `vYYYY.M.D`, e.g. `v2026.4.23`) and update the default
# below. Use `main` only if you accept that every rebuild can pull arbitrary
# new upstream commits.
ARG HERMES_REF=v2026.5.16

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
    apt-get install -y --no-install-recommends curl ca-certificates git tini ffmpeg libopus0 \
        chromium fonts-liberation && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

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
# [all] in v2026.5.16: cron, cli, dev, pty, mcp, homeassistant, sms, acp,
# google, web, youtube. Messaging platforms, TTS, and other heavy backends
# are now lazy-installed by hermes at first use. We pre-install the ones
# this template actually uses so first-message latency is instant.
# When bumping HERMES_REF, re-check hermes-agent's pyproject.toml [all] and
# the extras below against the new release's pyproject.toml.
RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[all,messaging,tts-premium,honcho,bedrock,anthropic,edge-tts,hindsight]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm

# --- Fix: Chromium-Flags nicht an Lightpanda geben ---------------------------
# Hermes injiziert als root automatisch
#   AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage"
# (tools/browser_tool.py, _needs_sandbox_bypass). Das sind Chrome-Flags, und
# Lightpanda lehnt sie ab:
#   "Custom Chrome arguments (--args) are not supported with Lightpanda"
# Folge: JEDER Browser-Befehl schlug fehl, Hermes startete den Chrome-Fallback,
# und ohne Chromium endete das in
#   "Chrome fallback failed: could not determine current URL"
# Das Skript hängt `and engine != "lightpanda"` an den Injection-Guard und lässt
# den BUILD LAUT fehlschlagen, falls Upstream den Block je umbaut (gleiche
# Philosophie wie der CDP-Smoke-Test oben) — statt still ein kaputtes
# Browser-Toolset auszuliefern. Idempotent.
COPY patch-browser-engine.py /app/patch-browser-engine.py
RUN python3 /app/patch-browser-engine.py

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

#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
#
# hermes >= v2026.7.1 consolidated several dirs; they now resolve via
# get_hermes_dir("<new>", "<old>") which prefers the NEW path unless the OLD one
# already holds content. Seeding an empty legacy stub no longer claims it, so we
# seed the new paths: pairing -> platforms/pairing, image_cache -> cache/images,
# audio_cache -> cache/audio. A populated legacy dir from an older deploy still
# wins, so existing volumes keep working. (Synced with upstream's start.sh.)
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/platforms/pairing \
         /data/.hermes/hooks /data/.hermes/cache/images /data/.hermes/cache/audio \
         /data/.hermes/workspace /data/.hermes/skins /data/.hermes/plans \
         /data/.hermes/home

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f /data/.hermes/auth.json ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > /data/.hermes/auth.json
  chmod 600 /data/.hermes/auth.json
fi

# Installiere SSH-Client, falls er fehlt
if ! command -v ssh >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y openssh-client
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache openssh-client
  fi
fi

# Setup GitHub SSH Access (Fail-Safe)
if [ -n "$HERMES_SSH_KEY" ]; then
  mkdir -p ~/.ssh || true
  # printf ist sicherer als echo bei mehrzeiligen SSH-Keys
  printf '%s\n' "$HERMES_SSH_KEY" > ~/.ssh/id_ed25519 || true
  chmod 600 ~/.ssh/id_ed25519 || true
  ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true
  git config --global user.name "Hermes Agent" || true
  git config --global user.email "gerald.schranz@gmail.com" || true
fi

# Stamp the install method as "docker" so hermes treats this as an immutable
# container image rather than a pip checkout. detect_install_method() reads this
# before its .git / pip fallback; without it the dashboard's "Update Hermes"
# button may offer an in-container pip upgrade that would desync the Python
# package from this image's pre-built web_dist/ui-tui bundles. The real upgrade
# path is bumping HERMES_REF and redeploying. Rewritten each boot to self-heal.
printf 'docker\n' > /data/.hermes/.install_method

# Clear stale gateway runtime files left over from the previous container.
# hermes writes these on start but does not remove them on SIGTERM, and /data is
# a persistent volume, so they survive into the next boot:
#   gateway.pid  -> "PID file race lost to another gateway instance"
#   gateway.lock -> since v2026.8.27 get_running_pid() also consults the lock,
#                   and the host-wide gate makes `--replace` REFUSE a pid it
#                   cannot prove owns this HERMES_HOME (gateway/run.py
#                   "Refusing --replace"), which no retry can clear
#   gateway.sock -> a stale control socket blocks the fresh bind
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing all three unconditionally is safe.
rm -f /data/.hermes/gateway.pid /data/.hermes/gateway.lock /data/.hermes/gateway.sock

exec python /app/server.py

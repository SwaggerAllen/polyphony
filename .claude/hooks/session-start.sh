#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# The base image ships Elixir 1.14 / OTP 25 with its OTP include headers stripped,
# which blocks modern deps (Phoenix 1.8, LiveView 1.0, Plug 1.19+, Floki 0.37+ all
# require Elixir 1.15+) and forces build workarounds (Floki's leex lexer and
# Phoenix's cert task both need OTP headers). This hook installs a modern toolchain
# — OTP 27 (precompiled for Ubuntu 24.04, *with* headers) + Elixir 1.17 — into /opt
# and puts it on PATH, so every session comes up ready with no workarounds.
#
# Idempotent: skips the (large) downloads once the tools are present, so cached
# sessions start fast. Remote-only.
set -euo pipefail

# Only run in Claude Code on the web (leave a local machine's toolchain alone).
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

OTP_VERSION="27.3.4.9"
ELIXIR_VERSION="1.17.3"
OTP_DIR="/opt/otp-${OTP_VERSION}"
ELIXIR_DIR="/opt/elixir-${ELIXIR_VERSION}-otp27"

# ── OTP (precompiled, Ubuntu 24.04, includes headers) ─────────────────────────
if [ ! -x "${OTP_DIR}/bin/erl" ]; then
  echo "[session-start] installing Erlang/OTP ${OTP_VERSION}…"
  curl -fsSL "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz" -o /tmp/otp.tar.gz
  mkdir -p "${OTP_DIR}"
  tar -xzf /tmp/otp.tar.gz -C "${OTP_DIR}" --strip-components=1
  # Fix the precompiled build's baked-in RootDir for this location.
  ( cd "${OTP_DIR}" && ./Install -minimal "${OTP_DIR}" >/dev/null )
  rm -f /tmp/otp.tar.gz
fi

# ── Elixir (matching OTP 27 build) ────────────────────────────────────────────
if [ ! -x "${ELIXIR_DIR}/bin/elixir" ]; then
  echo "[session-start] installing Elixir ${ELIXIR_VERSION}…"
  curl -fsSL "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-27.zip" -o /tmp/elixir.zip
  mkdir -p "${ELIXIR_DIR}"
  unzip -qo /tmp/elixir.zip -d "${ELIXIR_DIR}"
  rm -f /tmp/elixir.zip
fi

# ── Persist PATH + locale for the whole session ───────────────────────────────
# OTP 27 warns under a latin1 locale; +fnu (and a UTF-8 LANG) silences it.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"${OTP_DIR}/bin:${ELIXIR_DIR}/bin:\$PATH\""
    echo 'export ELIXIR_ERL_OPTIONS="+fnu"'
    echo 'export LANG="${LANG:-C.UTF-8}"'
  } >> "${CLAUDE_ENV_FILE}"
fi

# Make the toolchain available within this hook run too.
export PATH="${OTP_DIR}/bin:${ELIXIR_DIR}/bin:${PATH}"
export ELIXIR_ERL_OPTIONS="+fnu"
export LANG="${LANG:-C.UTF-8}"

# ── Hex/rebar + project deps ──────────────────────────────────────────────────
mix local.hex --force >/dev/null 2>&1 || true
mix local.rebar --force >/dev/null 2>&1 || true
if [ -f "${CLAUDE_PROJECT_DIR:-.}/mix.exs" ]; then
  ( cd "${CLAUDE_PROJECT_DIR:-.}" && mix deps.get >/dev/null 2>&1 || true )
fi

# ── Postgres (read models need it; the base image starts it down) ─────────────
pg_ctlcluster 16 main start >/dev/null 2>&1 || true

echo "[session-start] ready: $(elixir --version 2>/dev/null | tail -1)"

#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# The base image ships Elixir 1.14 / OTP 25 with its OTP include headers stripped,
# which blocks modern deps (Phoenix 1.8 / LiveView 1.0 / Plug 1.19+ / Floki 0.37+
# all require Elixir 1.15+) and forces build workarounds (Floki's leex lexer and
# Phoenix's cert task both need OTP headers). This hook installs a modern toolchain
# — OTP 27 (precompiled for Ubuntu 24.04, *with* headers) + Elixir 1.17 — into /opt
# and puts it on PATH.
#
# It first checks the *system* toolchain: once the base environment is itself
# updated to a modern OTP/Elixir, this hook detects that and skips the install
# entirely, so it stops costing startup time. It also skips the downloads when its
# own /opt copy is already present (warm/cached container).
set -euo pipefail

# Run asynchronously: the session starts while this runs in the background. Safe
# because the common cases are cheap — a modern system toolchain is a no-op, and a
# warm container skips the downloads. Only a cold container with an un-updated base
# pays the ~15s install (and even then the agent is usually reading/planning first).
echo '{"async": true, "asyncTimeout": 300000}'

# Only run in Claude Code on the web (leave a local machine's toolchain alone).
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Floors below which we consider the environment out of date and shim a modern
# toolchain. Once the base image meets these, the hook no-ops the install.
MIN_OTP=26
MIN_ELIXIR_MINOR=16

OTP_VERSION="27.3.4.9"
ELIXIR_VERSION="1.17.3"
OTP_DIR="/opt/otp-${OTP_VERSION}"
ELIXIR_DIR="/opt/elixir-${ELIXIR_VERSION}-otp27"

# ── Is the system toolchain already modern enough? ────────────────────────────
sys_otp="$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || true)"
# Parse the "Elixir X.Y.Z" line specifically — `elixir --version` prints the Erlang
# banner (with an erts X.Y.Z) first, so a naive version grep would match that.
sys_ex="$(elixir --version 2>/dev/null | sed -n 's/^Elixir \([0-9][0-9.]*\).*/\1/p' | head -1 || true)"
sys_ex_minor="$(printf '%s' "$sys_ex" | cut -d. -f2)"

toolchain_ok=false
if [ -n "$sys_otp" ] && [ -n "$sys_ex_minor" ] \
  && [ "$sys_otp" -ge "$MIN_OTP" ] 2>/dev/null \
  && [ "$sys_ex_minor" -ge "$MIN_ELIXIR_MINOR" ] 2>/dev/null; then
  toolchain_ok=true
fi

if [ "$toolchain_ok" = true ]; then
  echo "[session-start] system toolchain is current (OTP ${sys_otp} / Elixir ${sys_ex}) — no shim needed" >&2
else
  # ── Install OTP 27 (precompiled, Ubuntu 24.04, includes headers) ────────────
  if [ ! -x "${OTP_DIR}/bin/erl" ]; then
    echo "[session-start] installing Erlang/OTP ${OTP_VERSION}…" >&2
    curl -fsSL "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz" -o /tmp/otp.tar.gz
    mkdir -p "${OTP_DIR}"
    tar -xzf /tmp/otp.tar.gz -C "${OTP_DIR}" --strip-components=1
    ( cd "${OTP_DIR}" && ./Install -minimal "${OTP_DIR}" >/dev/null )
    rm -f /tmp/otp.tar.gz
  fi

  # ── Install the matching Elixir ─────────────────────────────────────────────
  if [ ! -x "${ELIXIR_DIR}/bin/elixir" ]; then
    echo "[session-start] installing Elixir ${ELIXIR_VERSION}…" >&2
    curl -fsSL "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-27.zip" -o /tmp/elixir.zip
    mkdir -p "${ELIXIR_DIR}"
    unzip -qo /tmp/elixir.zip -d "${ELIXIR_DIR}"
    rm -f /tmp/elixir.zip
  fi

  # ── Persist PATH + locale for the session, and use it in this run ───────────
  # OTP 27 warns under a latin1 locale; +fnu (and a UTF-8 LANG) silences it.
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    {
      echo "export PATH=\"${OTP_DIR}/bin:${ELIXIR_DIR}/bin:\$PATH\""
      echo 'export ELIXIR_ERL_OPTIONS="+fnu"'
      echo 'export LANG="${LANG:-C.UTF-8}"'
    } >> "${CLAUDE_ENV_FILE}"
  fi
  export PATH="${OTP_DIR}/bin:${ELIXIR_DIR}/bin:${PATH}"
  export ELIXIR_ERL_OPTIONS="+fnu"
  export LANG="${LANG:-C.UTF-8}"
fi

# ── Common setup (both paths): hex/rebar, deps, Postgres ──────────────────────
mix local.hex --force >/dev/null 2>&1 || true
mix local.rebar --force >/dev/null 2>&1 || true
if [ -f "${CLAUDE_PROJECT_DIR:-.}/mix.exs" ]; then
  ( cd "${CLAUDE_PROJECT_DIR:-.}" && mix deps.get >/dev/null 2>&1 || true )
fi
pg_ctlcluster 16 main start >/dev/null 2>&1 || true

echo "[session-start] ready: $(elixir --version 2>/dev/null | tail -1)" >&2

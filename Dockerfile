# Multi-stage build for the Polyphony Phoenix release.
#
# Builder compiles deps + app, builds+digests assets (esbuild/tailwind), and cuts
# a mix release. The runner is a slim Debian with just the OTP runtime libs and the
# assembled release — no Elixir/Mix, no build tools.
#
# Base images pin Elixir 1.17.3 / Erlang-OTP 27 on Debian bookworm to match the
# project toolchain. Bump ARGs together when upgrading.

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250630-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ── Builder ───────────────────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

# git for any git deps; build-essential for NIFs (e.g. lazy_html is test-only, but
# other NIFs may compile). curl is used by the esbuild/tailwind installers.
RUN apt-get update -y \
  && apt-get install -y build-essential git curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Deps first (cache-friendly): fetch only prod deps, then compile them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config (config.exs + prod.exs). runtime.exs is copied later so a
# change to it doesn't bust the deps-compile cache.
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# Fetch the esbuild + tailwind standalone binaries, then build+digest assets.
COPY assets assets
COPY priv priv
RUN mix assets.setup
COPY lib lib
RUN mix assets.deploy

# Compile the app and assemble the release.
RUN mix compile
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ── Runner ────────────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the runtime locale to UTF-8 (OTP warns otherwise; also correct for text).
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Run as an unprivileged user.
RUN chown nobody /app
USER nobody

ENV MIX_ENV="prod"

# Copy the assembled release from the builder.
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/polyphony ./

EXPOSE 4000

# `bin/server` execs `bin/polyphony start` (prod sets server: true).
CMD ["/app/bin/server"]

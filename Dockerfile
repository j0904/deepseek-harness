# syntax=docker/dockerfile:1
# DeepSeek Harness (`dsh`) container image.
#
# Multi-stage build from the local checkout:
#   1. builder — installs dependencies with pnpm and runs `pnpm run build`
#              (host native addon, tsc/tsdown lib output, web frontend).
#              Needs git: scripts/client-build-environment.ts stamps the build
#              from `git rev-parse HEAD`, so .git must stay in the context.
#   2. runtime — slim Node image with the built tree, launched through the
#              same source entrypoint the repo uses (`pnpm dsh ...`).
#              Full node_modules are kept because the launcher runs through
#              tsx (a devDependency).
#
# The web profile serves on port 3080. DSH_HOME (sessions, profiles,
# credentials) lives in /data — mount a volume there to persist it.
# The model needs a provider key: pass -e DEEPSEEK_API_KEY=... at run time.
#
# The dai branch's client/connection links bigtangle-ts from the sibling wallet
# checkout (`link:../../../../wallet/packages/bigtangle-ts`), which is outside
# this build context. Stage it before building (the dir is gitignored; its own
# deps are installed in-image):
#   cp -a ../wallet/packages/bigtangle-ts bigtangle-ts
#   ./deploy.sh

ARG NODE_VERSION=24

FROM node:${NODE_VERSION}-bookworm AS builder

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable && corepack prepare pnpm@11.7.0 --activate

# Toolchain for the host native addon and node-gyp fallbacks, plus git for
# build version stamping (see header).
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential python3 git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
# The dai branch links bigtangle-ts from the sibling wallet checkout, which is
# outside this build context. The staged copy lands at /app/bigtangle-ts; the
# link resolves to the absolute path below, so satisfy it before install, and
# give the package its own deps (the wallet monorepo hoists them at its root,
# so the staged copy is not self-contained).
RUN mkdir -p /wallet/packages \
  && ln -s /app/bigtangle-ts /wallet/packages/bigtangle-ts \
  && cd /app/bigtangle-ts \
  && npm install --omit=dev --ignore-scripts --no-audit --no-fund
RUN pnpm install --frozen-lockfile && pnpm run build

FROM node:${NODE_VERSION}-bookworm-slim AS runtime

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  NODE_ENV=production \
  DSH_HOME=/data

# pnpm for `dsh plugin ...` profile transactions; git for git-based plugins.
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable && corepack prepare pnpm@11.7.0 --activate \
  && mkdir -p /data && chown node:node /data

WORKDIR /app
COPY --from=builder --chown=node:node /app /app
# same out-of-context link as the builder stage
RUN mkdir -p /wallet/packages \
  && ln -s /app/bigtangle-ts /wallet/packages/bigtangle-ts

USER node
VOLUME /data
EXPOSE 3080

ENTRYPOINT ["node", "--import", "tsx/esm", "apps/cli/src/bin.ts"]
CMD ["web", "--host", "0.0.0.0", "--port", "3080", "--no-open"]

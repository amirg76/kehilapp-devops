# ─────────────────────────────────────────────────────────────────────────────
# Backend production image  (Node 20 / Express)
#
# WHY multi-stage: the "builder" stage has all the npm machinery and dev files;
# the final "runtime" stage copies ONLY what the app needs to run. Result: a
# smaller, cleaner image with no build tools or dev dependencies to attack.
#
# Build context is the backend repo. From this devops repo you build it like:
#   docker build -f docker/backend.Dockerfile -t kehilapp-backend:local ../kehilapp-backend-hardened
# (docker-compose.yml already wires the context + dockerfile for you.)
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: install production dependencies ────────────────────────────────
# --platform=$BUILDPLATFORM: this stage only runs `npm ci` on pure-JavaScript
# dependencies (bcryptjs, not bcrypt; no sharp, no native addons — check
# package.json before adding one), so the resulting node_modules is the same
# for every CPU and can be produced on the builder's own architecture instead
# of under QEMU emulation. Together with the RUN-free runtime stage below, the
# arm64 image builds anywhere buildx can pull arm64 base layers — no emulator
# needed. If a native dependency is ever added, drop this flag.
FROM --platform=$BUILDPLATFORM node:20-alpine AS deps
WORKDIR /app

# Copy only the manifest first. Docker caches this layer, so `npm ci` re-runs
# ONLY when package.json / package-lock.json change — not on every code edit.
COPY package.json package-lock.json ./

# `npm ci` = clean, reproducible install straight from the lockfile.
# `--omit=dev` drops devDependencies (jest, eslint, babel…) — not needed at runtime.
RUN npm ci --omit=dev && npm cache clean --force

# ── Stage 2: final runtime image ────────────────────────────────────────────
FROM node:20-alpine AS runtime

# NO `RUN` in this stage, on purpose. Every RUN executes a binary of the
# TARGET architecture, which on an x86 builder means QEMU emulation for the
# arm64 image — slow, and impossible where no emulator is registered (this
# stage used to `apk add tini` and `chown -R`, and the local arm64 build died
# on "exec format error" at the first one, 29.9). COPY needs no execution.
#
# The init process (zombie reaping, clean signal forwarding on `docker stop`)
# comes from `init: true` in both compose files — Docker's own tini — instead
# of one installed here. wget for the healthcheck is in alpine's busybox.

ENV NODE_ENV=production
WORKDIR /app

# SECURITY: never run as root. node:alpine ships a pre-made "node" user
# (uid 1000). Files are copied already owned by it — no chown step needed.
# Bring in the already-installed node_modules from the deps stage…
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
# …then the application source. .dockerignore keeps .env/tests/docs out.
COPY --chown=node:node . .
USER node

# Documented port. The app itself reads $PORT (defaults to 5001 in src/index.js).
EXPOSE 5001

# HEALTHCHECK: Docker/compose mark the container "healthy" only when /healthz
# returns 200. /healthz is the liveness probe ("is the process up") — it never
# touches Mongo, so a DB blip won't flap the container. (Readiness = /readyz.)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:5001/healthz || exit 1

# No tini entrypoint: compose runs the container with `init: true`.
CMD ["node", "src/index.js"]

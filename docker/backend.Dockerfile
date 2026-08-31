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
FROM node:20-alpine AS deps
WORKDIR /app

# Copy only the manifest first. Docker caches this layer, so `npm ci` re-runs
# ONLY when package.json / package-lock.json change — not on every code edit.
COPY package.json package-lock.json ./

# `npm ci` = clean, reproducible install straight from the lockfile.
# `--omit=dev` drops devDependencies (jest, eslint, babel…) — not needed at runtime.
RUN npm ci --omit=dev && npm cache clean --force

# ── Stage 2: final runtime image ────────────────────────────────────────────
FROM node:20-alpine AS runtime

# wget (used by the healthcheck below) ships in alpine's busybox already.
# tini is a tiny init that reaps zombie processes and forwards signals so
# `docker stop` shuts Node down cleanly instead of killing it after 10s.
RUN apk add --no-cache tini

ENV NODE_ENV=production
WORKDIR /app

# Bring in the already-installed node_modules from the deps stage…
COPY --from=deps /app/node_modules ./node_modules
# …then the application source. .dockerignore keeps node_modules/.env/tests out.
COPY . .

# SECURITY: never run as root. node:alpine ships a pre-made "node" user (uid 1000).
# Give it ownership of the app dir, then drop to it.
RUN chown -R node:node /app
USER node

# Documented port. The app itself reads $PORT (defaults to 5001 in src/index.js).
EXPOSE 5001

# HEALTHCHECK: Docker/compose mark the container "healthy" only when /healthz
# returns 200. /healthz is the liveness probe ("is the process up") — it never
# touches Mongo, so a DB blip won't flap the container. (Readiness = /readyz.)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:5001/healthz || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/index.js"]

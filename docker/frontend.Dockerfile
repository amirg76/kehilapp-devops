# ─────────────────────────────────────────────────────────────────────────────
# Public frontend (kehilapp-front-hardened)  —  Vite build → static files → nginx
#
# A React/Vite app is just HTML/CSS/JS after `vite build`. There is no Node
# server to run in production: we build the static files in a throwaway Node
# stage, then serve them with a tiny nginx image. Small, fast, nothing to hack.
#
# NOTE: this repo's vite.config.js sets  build.outDir = "build"  (not "dist").
#
# The SPA-aware nginx config lives in docker/nginx/spa.nginx.conf and is mounted
# into the container by docker-compose (so it stays editable without a rebuild).
# The default nginx image already serves /usr/share/nginx/html on port 80.
#
# Build context = the frontend repo:
#   docker build -f docker/frontend.Dockerfile -t kehilapp-frontend:local ../kehilapp-front-hardened
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: build the static bundle ────────────────────────────────────────
FROM node:20-alpine AS build
WORKDIR /app

# Vite bakes API URLs into the bundle AT BUILD TIME. Anything the app reads as
# import.meta.env.VITE_* must be passed here as a build arg, not at runtime.
# Override per environment:  --build-arg VITE_API_BASE_URL=https://api.example.com
ARG VITE_API_BASE_URL=/api
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}

COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build          # outputs to /app/build (see vite.config.js)

# ── Stage 2: serve with nginx ───────────────────────────────────────────────
FROM nginx:1.27-alpine AS runtime
COPY --from=build /app/build /usr/share/nginx/html

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:80/ || exit 1

CMD ["nginx", "-g", "daemon off;"]

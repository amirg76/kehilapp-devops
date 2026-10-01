# ─────────────────────────────────────────────────────────────────────────────
# Admin panel (kehilapp-admin-hardened)  —  Vite + TypeScript build → nginx
#
# Same pattern as the public frontend, with two differences:
#   • its build script runs `tsc && vite build` (TypeScript type-check first)
#   • Vite's default output dir here is "dist" (this repo did not override it)
#
# Build context = the admin repo:
#   docker build -f docker/admin.Dockerfile -t kehilapp-admin:local ../kehilapp-admin-hardened
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: build ──────────────────────────────────────────────────────────
# --platform=$BUILDPLATFORM: static output, same for every CPU — see
# frontend.Dockerfile for why this avoids QEMU emulation on arm64 builds.
FROM --platform=$BUILDPLATFORM node:20-alpine AS build
WORKDIR /app

# VITE_API_BASE_URL: where the API is. The admin's own request paths already
# start with /api (src/api/kehilapp.ts), so this is the ORIGIN only — "" means
# same origin as the page. This used to be "/api", which produced /api/api/...;
# it only ever worked because the proxy was stripping one /api at the time.
# VITE_BASE_PATH: where the panel is served from. The proxy mounts it under
# /admin/, and vite.config.ts uses this for asset URLs and the router basename.
ARG VITE_API_BASE_URL=""
ARG VITE_BASE_PATH=/admin/
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
ENV VITE_BASE_PATH=${VITE_BASE_PATH}

COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build          # tsc && vite build → /app/dist

# ── Stage 2: serve with nginx ───────────────────────────────────────────────
FROM nginx:1.27-alpine AS runtime
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:80/ || exit 1

CMD ["nginx", "-g", "daemon off;"]

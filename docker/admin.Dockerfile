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
FROM node:20-alpine AS build
WORKDIR /app

ARG VITE_API_BASE_URL=/api
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}

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

# syntax=docker/dockerfile:1

# Multi-stage build for the attobot admin dashboard.
#   1. build the React SPA (Vite)        -> /web/dist
#   2. build the Fastify server (tsc)    -> /app/dist
#   3. minimal runtime: node + server bundle + prod deps + static SPA
# Build context is ./dashboard (see docker-compose.yml).

# ---- stage 1: build the SPA -----------------------------------------------
FROM node:22-slim AS web-build
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# ---- stage 2: build the server (TypeScript -> JS) -------------------------
FROM node:22-slim AS server-build
WORKDIR /app
COPY server/package.json server/package-lock.json ./
RUN npm ci
COPY server/tsconfig.json ./
COPY server/src ./src
RUN npx tsc -p tsconfig.json

# ---- stage 3: runtime -----------------------------------------------------
FROM node:22-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8088
# Production-only dependencies (no typescript/tsx).
COPY server/package.json server/package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
# Compiled server + built SPA (served as static from /app/public).
COPY --from=server-build /app/dist ./dist
COPY --from=web-build /web/dist ./public
EXPOSE 8088
CMD ["node", "dist/index.js"]

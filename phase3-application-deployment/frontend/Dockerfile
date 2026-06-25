# ── Stage 1: Build ────────────────────────────────────────────────────────────
# Node 22 LTS (Active LTS since Oct 2024) Alpine — includes npm and build tools.
FROM node:22-alpine AS builder

WORKDIR /app

# Install dependencies first (separate layer — cached unless package.json changes)
COPY package*.json ./
RUN npm ci --include=dev

# Copy source and build the Vite SPA
COPY index.html ./
COPY vite.config.js ./
COPY src/ ./src/

RUN npm run build
# Output: /app/dist — static HTML, JS, and CSS bundles


# ── Stage 2: Serve ─────────────────────────────────────────────────────────────
# nginx 1.27 stable-mainline Alpine (~5 MB); no Node runtime in the final image.
FROM nginx:1.27-alpine

# Remove the default nginx config
RUN rm /etc/nginx/conf.d/default.conf

# SPA-aware nginx config (all routes → index.html for React Router)
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy built assets from stage 1
COPY --from=builder /app/dist /usr/share/nginx/html

# nginx official image already drops to the 'nginx' user in the entrypoint;
# ownership must allow that user to read the static files.
RUN chown -R nginx:nginx /usr/share/nginx/html \
 && chmod -R 755 /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost/health || exit 1

CMD ["nginx", "-g", "daemon off;"]

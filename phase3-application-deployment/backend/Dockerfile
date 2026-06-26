# Multi-stage build: builder installs all deps; production image only ships runtime deps,
# reducing image size and attack surface.
FROM node:22-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY src/        ./src/
COPY migrations/ ./migrations/

FROM node:22-alpine

WORKDIR /app

RUN addgroup -S appgroup \
 && adduser -S appuser -G appgroup

COPY package*.json ./
RUN npm ci --omit=dev \
 && npm cache clean --force

COPY --from=builder /app/src        ./src/
COPY --from=builder /app/migrations ./migrations/

RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]

# Node 22 LTS Alpine (Active LTS since Oct 2024) — minimal base; pure JS project.
FROM node:22-alpine

WORKDIR /app

# Create a non-root user before copying files
RUN addgroup -S appgroup \
 && adduser -S appuser -G appgroup

# Install production dependencies only
COPY package*.json ./
RUN npm ci --omit=dev \
 && npm cache clean --force

# Copy application source
COPY src/        ./src/
COPY migrations/ ./migrations/

# Transfer ownership to non-root user
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]

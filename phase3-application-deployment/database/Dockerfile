# PostgreSQL 17 Alpine — official image; runs as 'postgres' user (uid 70).
# PG 17 (Sep 2024): faster vacuum, improved logical replication, better performance.
FROM postgres:17-alpine

# Environment defaults — overridden at runtime by Kubernetes Secret/ConfigMap.
# These values are placeholders; never ship real credentials in an image.
ENV POSTGRES_DB=bmidb \
    POSTGRES_USER=bmi_user \
    POSTGRES_PASSWORD=changeme

# PostgreSQL init scripts execute in filename order on first container start.
# 001 creates the schema; 002 is an idempotent guard for the measurement_date column.
# These SQL files are copied into the database/ directory before building.
COPY init/001_create_measurements.sql /docker-entrypoint-initdb.d/001_create_measurements.sql
COPY init/002_add_measurement_date.sql /docker-entrypoint-initdb.d/002_add_measurement_date.sql

# Performance tuning — custom config is mounted at runtime via ConfigMap if needed
# Postgres 17 default config works fine without custom tuning for this workload

EXPOSE 5432

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1

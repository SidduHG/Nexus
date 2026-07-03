# Nexus Postgres image — ONE engine, three jobs:
#   relational/JSONB (native) + vector search (pgvector) + property graph (Apache AGE)
#
# Base image already contains PostgreSQL 16 + pgvector.
# We compile Apache AGE from its PG16 branch on top (AGE has no reliable
# prebuilt image that also carries pgvector — this Dockerfile is the fix).
#
# Build:  docker compose build postgres     (from the db/ directory)
FROM pgvector/pgvector:pg16

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        ca-certificates \
        postgresql-server-dev-16 \
        flex \
        bison \
    && git clone --depth 1 --branch PG16 https://github.com/apache/age.git /tmp/age \
    && cd /tmp/age \
    && make PG_CONFIG=/usr/bin/pg_config install \
    && apt-get purge -y build-essential git flex bison \
    && apt-get autoremove -y \
    && rm -rf /tmp/age /var/lib/apt/lists/*

# AGE is loaded per-database via CREATE EXTENSION (see migration 0003).
# shared_preload_libraries is set in docker-compose command so sessions
# don't each need an explicit LOAD 'age'.

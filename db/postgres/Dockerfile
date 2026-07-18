# Nexus Postgres image — relational/JSONB + pgvector.
#
# pgvector isn't used by any v0.1 table yet (0001_core.sql only enables the
# extension ahead of time); kept because it's zero-cost and the official
# base image already bundles it. No other extensions needed at this scope.
#
# Build:  docker compose build postgres     (from the db/ directory)
FROM pgvector/pgvector:pg16

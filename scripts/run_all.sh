#!/usr/bin/env bash
# Rebuilds the warehouse from scratch, runs the tests, then executes every analysis.
# Connection settings come from the standard PGHOST, PGPORT, PGUSER, PGPASSWORD variables.
set -euo pipefail

cd "$(dirname "$0")/.."
DB_NAME="${DB_NAME:-freight_dw}"

psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME}" -c "CREATE DATABASE ${DB_NAME}"

run() { psql -X -q -v ON_ERROR_STOP=1 -d "$DB_NAME" "$@"; }

for file in sql/0*.sql; do
    echo "==> ${file}"
    run -f "$file" > /dev/null
done

echo "==> Loading warehouse"
run -c "CALL etl.run_load()" -c "CALL etl.refresh_marts()" -c "ANALYZE"

echo "==> Running tests"
run -f tests/data_quality.sql

mkdir -p output
for file in analysis/*.sql; do
    name="$(basename "$file" .sql)"
    echo "==> ${file}"
    run --csv -f "$file" > "output/${name}.csv"
done

echo "Done. Analysis results are in output/."

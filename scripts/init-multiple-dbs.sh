#!/usr/bin/env bash
set -e

# Create multiple databases for AEGIS platform services
for db in temporal aegis seaweedfs; do
    echo "  Creating database: $db"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        SELECT 'CREATE DATABASE $db OWNER $POSTGRES_USER'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
        GRANT ALL PRIVILEGES ON DATABASE $db TO $POSTGRES_USER;
EOSQL
done

#!/usr/bin/env bash

set -e

echo "Initializing Service databases..."

create_user_and_database() {
  local database_name="$1"
  local database_user="$2"
  local database_password="$3"

  echo "Configuring database '${database_name}'..."

  psql \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --set=database_name="$database_name" \
    --set=database_user="$database_user" \
    --set=database_password="$database_password" <<'EOSQL'

SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L',
    :'database_user',
    :'database_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = :'database_user'
)
\gexec

SELECT format(
    'CREATE DATABASE %I OWNER %I',
    :'database_name',
    :'database_user'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = :'database_name'
)
\gexec

EOSQL
}


create_user_and_database \
  "$SERVICE_DB_NAME" \
  "$SERVICE_DB_USER" \
  "$SERVICE_DB_PASSWORD"


create_user_and_database \
  "$SERVICE_TEST_DB_NAME" \
  "$SERVICE_TEST_DB_USER" \
  "$SERVICE_TEST_DB_PASSWORD"


create_user_and_database \
  "$KC_DB_NAME" \
  "$KC_DB_USER" \
  "$KC_DB_PASSWORD"


echo "Service databases initialized successfully."

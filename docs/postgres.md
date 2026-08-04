# PostgreSQL Database Backend

## Overview

This Jellyfin image supports PostgreSQL as an optional database backend.
By default, SQLite is used (no configuration needed). PostgreSQL is
enabled by setting `POSTGRES_ENABLED=true` and providing connection
details via environment variables.

## Quick Start (fresh install, no existing data)

### Docker Compose

See `docker-compose.postgres.yml` for a complete stack with PostgreSQL 16.

### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| POSTGRES_ENABLED | Yes | false | Set to "true" to enable |
| POSTGRES_HOST | Yes | - | PostgreSQL server hostname/IP |
| POSTGRES_PORT | No | 5432 | Server port |
| POSTGRES_DB | No | jellyfin | Database name |
| POSTGRES_USER | No | jellyfin | Database user |
| POSTGRES_PASSWORD | Yes | - | Database password |
| POSTGRES_SSL_MODE | No | Prefer | SSL mode |
| POSTGRES_MAX_POOL_SIZE | No | 128 | Connection pool max |
| POSTGRES_TIMEOUT | No | 60 | Command timeout (seconds) |

### How It Works

1. Container starts, entrypoint detects `POSTGRES_ENABLED=true`
2. Validates required env vars, waits for PostgreSQL to be ready
3. Writes `/config/config/database.xml` with `PLUGIN_PROVIDER` config
4. Jellyfin loads the Pgsql plugin and connects via Npgsql
5. EF Core runs migrations, seeding the database schema
6. First-run setup wizard creates initial configuration

## Migrating from SQLite to PostgreSQL

ADVANCED -- requires technical knowledge of pgloader.
This is a one-time offline migration.

### Prerequisites

- Existing Jellyfin SQLite database
- A running PostgreSQL server with an **empty** `jellyfin` database
- The `pgloader` tool installed

### Steps

1. **Create an empty PostgreSQL database:**
   ```sql
   CREATE DATABASE jellyfin;
   CREATE USER jellyfin WITH PASSWORD 'your-password';
   GRANT ALL PRIVILEGES ON DATABASE jellyfin TO jellyfin;
   ```

2. **Configure this image for PostgreSQL** but do not yet connect it to
   your existing config directory. Use a fresh temporary config.

3. **Start Jellyfin once** with the empty PostgreSQL database. This seeds
   the `__EFMigrationsHistory` table. Stop after it reaches the setup
   wizard page.

4. **Install pgloader:**
   ```bash
   apt install pgloader
   ```

5. **Create `jellyfindb.load`:**
   ```
   LOAD DATABASE
        FROM sqlite:///path/to/old/jellyfin.db
        INTO pgsql://jellyfin:your-password@postgres-host:5432/jellyfin

   WITH include drop, create tables, create indexes, reset sequences,
        disable triggers

   SET maintenance_work_mem to '128MB', work_mem to '12MB'
   ```

6. **Run pgloader:**
   ```bash
   pgloader jellyfindb.load
   ```

7. **Restore your config** and restart Jellyfin with PostgreSQL enabled.

## Troubleshooting

### "PostgreSQL did not become reachable within 60 seconds"
- Verify PostgreSQL is running and reachable from the container
- Check firewall rules and Docker network configuration

### "Missing required env vars: POSTGRES_HOST"
- POSTGRES_HOST and POSTGRES_PASSWORD are required when POSTGRES_ENABLED=true

### "Cannot find the requested assembly"
- The Pgsql plugin was not built into the image
- Verify the Dockerfile build passed `POSTGRES_ENABLED=true`

### Plugin fails to load
- Check Jellyfin logs for ABI version mismatch
- The Pgsql plugin must target the same Jellyfin ABI version as the server
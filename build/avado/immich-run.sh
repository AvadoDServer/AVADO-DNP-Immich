#!/bin/bash
# Immich on AVADO: the four parts Immich's own docker-compose.yml runs as
# separate containers, in this one container (an AVADO package is one
# container): PostgreSQL with VectorChord, Valkey, machine learning (CPU) and
# the Immich server. If any part stops, the others are stopped cleanly and
# the container exits, so Docker starts the whole app again.
set -u

PGBIN=/usr/lib/postgresql/17/bin
PGROOT=/var/lib/postgresql
PGDATA=$PGROOT/data
PWFILE=$PGROOT/avado-db-password
log() { echo "[avado] $*"; }
# Run a program as another user. The long-running parts below call setpriv
# directly: it leaves no extra parent process (unlike runuser), so a stop
# signal reaches the program itself.
as_user() { _u=$1; shift; setpriv --reuid="$_u" --regid="$_u" --init-groups -- "$@"; }
# Wait up to $1 seconds for the given processes to end.
wait_gone() {
  _n=$(( $1 * 5 )); shift
  while [ "$_n" -gt 0 ]; do
    _alive=0
    for _p in "$@"; do kill -0 "$_p" 2>/dev/null && _alive=1; done
    [ "$_alive" = 0 ] && return 0
    sleep 0.2; _n=$(( _n - 1 ))
  done
  return 1
}

# ---- database -------------------------------------------------------------
mkdir -p "$PGDATA" /run/postgresql
chown postgres:postgres "$PGROOT" "$PGDATA" /run/postgresql
chmod 700 "$PGDATA"
if [ ! -s "$PWFILE" ]; then
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$PWFILE"
  chmod 600 "$PWFILE"
fi
DB_PASSWORD=$(cat "$PWFILE")

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  log "first start: creating the photo database"
  printf '%s\n' "$DB_PASSWORD" > /run/postgresql/pw
  chown postgres /run/postgresql/pw
  as_user postgres "$PGBIN/initdb" -D "$PGDATA" --username=postgres \
    --pwfile=/run/postgresql/pw --auth-local=peer --auth-host=scram-sha-256 \
    --encoding=UTF8 --locale=C.UTF-8 --data-checksums || exit 1
  rm -f /run/postgresql/pw
  cat >> "$PGDATA/postgresql.conf" <<'CONF'

# AVADO: Immich's database, reachable only inside this container.
listen_addresses = '127.0.0.1'
unix_socket_directories = '/run/postgresql'
shared_preload_libraries = 'vchord'
shared_buffers = 256MB
max_wal_size = 1GB
min_wal_size = 80MB
wal_compression = on
# Docker gives a container only 64 MB of shared memory (/dev/shm) and the
# AVADO package format cannot raise it (Immich's own compose file asks for
# 128 MB), so PostgreSQL keeps its shared work areas in the data folder.
dynamic_shared_memory_type = mmap
CONF
fi

setpriv --reuid=postgres --regid=postgres --init-groups -- "$PGBIN/postgres" -D "$PGDATA" &
PG_PID=$!
for _ in $(seq 1 120); do
  "$PGBIN/pg_isready" -q -h 127.0.0.1 -U postgres && break
  kill -0 "$PG_PID" 2>/dev/null || { log "the database did not start"; exit 1; }
  sleep 1
done
export PGPASSWORD=$DB_PASSWORD
if ! psql -h 127.0.0.1 -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='immich'" | grep -q 1; then
  psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE immich" >/dev/null || exit 1
fi
unset PGPASSWORD

# ---- queue (Valkey, nothing written to disk, as in Immich's compose file) --
setpriv --reuid=valkey --regid=valkey --init-groups -- valkey-server --bind 127.0.0.1 --port 6379 --protected-mode yes \
  --save "" --appendonly no --dir /tmp --loglevel warning &
VK_PID=$!

# ---- machine learning (CPU) ----------------------------------------------
(
  cd /usr/src || exit 1
  exec env IMMICH_HOST=127.0.0.1 IMMICH_PORT=3003 PYTHONPATH=/usr/src \
    PATH=/opt/venv/bin:$PATH VIRTUAL_ENV=/opt/venv \
    /opt/venv/bin/python -m immich_ml
) &
ML_PID=$!

# ---- Immich server ---------------------------------------------------------
# start_server [VAR=value ...]: the Immich server in the background. With
# AVADO_GROUP=1 it gets its own process group, so it can be stopped together
# with the worker processes it starts.
start_server() {
  (
    cd /usr/src/app || exit 1
    _launch=
    [ "${AVADO_GROUP:-0}" = 1 ] && _launch=setsid
    exec $_launch env IMMICH_HOST=127.0.0.1 IMMICH_PORT=2283 \
      DB_HOSTNAME=127.0.0.1 DB_PORT=5432 DB_USERNAME=postgres \
      DB_PASSWORD="$DB_PASSWORD" DB_DATABASE_NAME=immich \
      REDIS_HOSTNAME=127.0.0.1 REDIS_PORT=6379 \
      IMMICH_MACHINE_LEARNING_URL=http://127.0.0.1:3003 \
      "$@" start.sh
  ) &
}

# First start only: switch off Immich's "New update!" notice. Owners get
# Immich updates with the AVADO package and cannot update Immich themselves,
# so the notice only confuses (and the check asks GitHub every hour). Immich
# keeps its settings in tables it makes on its first start, so on that start
# the server first runs without its background worker (which does the version
# check), the setting is written, and then Immich starts normally. The owner
# can turn the check back on in Immich (Administration > Settings > Version
# check); this is never done again once Immich's tables exist.
db() { PGPASSWORD=$DB_PASSWORD psql -h 127.0.0.1 -U postgres -d immich -v ON_ERROR_STOP=1 -tAq "$@"; }
if [ "$(db -c "SELECT to_regclass('public.system_metadata') IS NOT NULL")" != t ]; then
  log "first start: preparing Immich's settings (about a minute)"
  AVADO_GROUP=1 start_server IMMICH_WORKERS_INCLUDE=api
  FIRST_PID=$!
  trap 'kill -TERM -- -"$FIRST_PID" 2>/dev/null; kill -TERM "$VK_PID" "$ML_PID" 2>/dev/null; wait_gone 5 "$FIRST_PID"; kill -INT "$PG_PID"; wait_gone 4 "$PG_PID"; exit 0' TERM INT
  for _ in $(seq 1 600); do
    curl -fs -o /dev/null http://127.0.0.1:2283/api/server/ping && break
    kill -0 "$FIRST_PID" 2>/dev/null || break
    sleep 1
  done
  if db -c "INSERT INTO system_metadata (key, value) VALUES ('system-config', '{\"newVersionCheck\": {\"enabled\": false}}') ON CONFLICT (key) DO NOTHING"; then
    log "first start: the update notice is off (AVADO brings Immich updates)"
  else
    log "first start: could not switch off the update notice; Immich works anyway"
  fi
  # Stop it with its worker processes (the API worker would otherwise keep
  # the port), then wait until the port is free for the real start.
  kill -TERM -- -"$FIRST_PID" 2>/dev/null
  for _ in $(seq 1 50); do
    pgrep -g "$FIRST_PID" >/dev/null || break
    sleep 0.2
  done
  kill -KILL -- -"$FIRST_PID" 2>/dev/null
  wait "$FIRST_PID" 2>/dev/null
  for _ in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 http://127.0.0.1:2283/api/server/ping
    [ $? = 7 ] && break
    sleep 1
  done
  trap - TERM INT
fi

start_server
SV_PID=$!

stopping=0
# Docker gives an app 10 seconds to stop, so: the server and machine learning
# get 5 seconds, then the queue, then a "fast" database shutdown, which
# writes everything to disk.
stop_all() {
  [ "$stopping" = 1 ] && return
  stopping=1
  log "stopping Immich"
  kill -TERM "$SV_PID" "$ML_PID" 2>/dev/null
  wait_gone 5 "$SV_PID" "$ML_PID" || kill -KILL "$SV_PID" "$ML_PID" 2>/dev/null
  kill -TERM "$VK_PID" 2>/dev/null
  kill -INT "$PG_PID" 2>/dev/null
  wait_gone 4 "$VK_PID" "$PG_PID"
  log "Immich stopped"
}
trap 'stop_all; exit 0' TERM INT

wait -n "$PG_PID" "$VK_PID" "$ML_PID" "$SV_PID"
code=$?
for p in PG:$PG_PID VK:$VK_PID ML:$ML_PID SV:$SV_PID; do
  kill -0 "${p#*:}" 2>/dev/null || log "part ${p%%:*} stopped (exit $code); restarting the app"
done
stop_all
exit 1

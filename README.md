# AVADO Immich

`immich.avado.dnp.dappnode.eth`: [Immich](https://immich.app) v3.4.1, photo and video backup for
the family's phones with search and face recognition, packaged for AVADO. Machine learning runs on
the processor (no graphics card needed).

- Page: **https://immich.my.ava.do** (http redirects to https: photos and passwords only go over
  https). While Immich starts, the page says "Immich is starting" and reloads itself.
- Data: three volumes, see below.
- Images: the official `immich-server` and `immich-machine-learning` v3.4.1 images, both pinned
  by digest.

## How it is put together

Immich's own `docker-compose.yml` runs four containers (server, machine learning, PostgreSQL with
VectorChord, Valkey). An AVADO package is one container, so this image holds all four:

| Part | What |
|---|---|
| `build/Dockerfile` | The official server image (Debian 13) + the machine-learning image's Python 3.13 runtime, `/opt/venv` and `immich_ml` copied in unchanged + PostgreSQL 17 with pgvector 0.8.7 (PostgreSQL project's Debian repository, pinned: VectorChord 0.4.3 needs pgvector >=0.7, <0.9) and VectorChord 0.4.3 (the version Immich's compose file uses; the `.deb` is checked by SHA-256) + Valkey + nginx. |
| `build/avado/immich-run.sh` | Starts the database (made on first start, with a random password kept in the database volume), Valkey (no disk writes), machine learning (`127.0.0.1:3003`) and the server (`127.0.0.1:2283`). If one part stops, the others are stopped and the container exits, so Docker restarts the whole app. On a stop signal it stops everything within Docker's 10 seconds: server and machine learning (5 s), then Valkey and a "fast" PostgreSQL shutdown. |
| `build/avado/avado-start.sh` | Start wrapper shared by the AVADO app packages: nginx on 80/443, the certificate check (15 s after start, then daily), `nice 10` for the app. |
| `build/avado/avado-certs.sh` | The `*.my.ava.do` certificate: the box's DAPPMANAGER copy (`http://dappmanager.my.ava.do/my.ava.do.crt`, as AVADO-DNP-Nethermind uses), else `http://iso.ava.do`, else the copy taken at build time. A copy is used only if it is for `*.my.ava.do`, valid for at least another hour and matches its key. |
| `build/avado/nginx.conf.in` | nginx: http redirects to https, uploads up to 50 GB, no request buffering (large videos), websockets, an "Immich is starting" page instead of a 502. |

Volumes:

| Volume | Path | What |
|---|---|---|
| `library` | `/data` | Photos, videos, thumbnails, encoded videos, Immich's own database backups. |
| `database` | `/var/lib/postgresql` | PostgreSQL 17 data and its password. |
| `models` | `/cache` | Machine-learning models (downloaded on first use, about 1 GB). |

First start: Immich's "New update!" notice is switched off (`newVersionCheck.enabled = false` in
Immich's own settings), because owners get Immich updates with the AVADO package and cannot act on
it; it also stops the hourly question to GitHub. Immich makes its settings tables on its first
start, so `immich-run.sh` runs the server once without its background worker (which does the
version check), writes the setting, stops it with its worker processes and then starts Immich
normally. This happens only while Immich's tables do not exist yet; the owner can switch the check
back on in Immich (Administration > Settings > Version check).

Fixed settings: `ORT_DISABLE_TELEMETRY=1` (onnxruntime, the machine-learning runtime, otherwise
sends usage data to Microsoft; Immich sets it itself since v3.3.6), one machine-learning worker, 2 threads per model, models unloaded after 5 minutes
idle (`MACHINE_LEARNING_*` in the Dockerfile), `IMMICH_TRUSTED_PROXIES=127.0.0.1`, PostgreSQL
`shared_buffers = 256MB` and `dynamic_shared_memory_type = mmap` (Docker's 64 MB `/dev/shm` cannot be
raised from an AVADO manifest; Immich's compose file asks for 128 MB).

## Resource use and the Ethereum node

AVADO's package format has no memory or CPU limits (the DAPPMANAGER's compose generator,
`build/src/src/utils/generate.js`, does not pass `mem_limit`, `cpus` or `shm_size`). Instead every
part runs at `nice 10`, so the node wins whenever the processor is busy, and machine learning is
limited to one worker with two threads. Measured on local Docker: about 1.9 GB of memory idle after
the first start, more while models are loaded.

## Who can reach it

Every device that can open `my.ava.do`: on the AVADO network (AVADO WiFi) or through Remote
Access. No port is opened on the home network. The first account made on the page becomes the
administrator.

## Updating

Bump both digests and the tag in `build/Dockerfile`, `upstream` and `version` in
`dappnode_package.json` and the image tag in `docker-compose.yml`. Read Immich's release notes
first: check the VectorChord version Immich's compose file uses (change `VCHORD_DEB` and
`VCHORD_SHA256` together) and the pgvector range it accepts (`PGVECTOR_VERSION`), keep PostgreSQL on major version 17 (a new major needs a data
migration), and remember that Immich cannot be downgraded and that a major Immich release may need
newer phone apps. The package has `autoupdate: true`, so a released version reaches every box that
has Immich.

## Licence

The packaging files in this repository are GPL-3.0 (see `LICENSE`). Immich is AGPL-3.0 and is used
unchanged from its official images. PostgreSQL, pgvector, VectorChord (AGPL-3.0 / ELv2), Valkey and
nginx come from their Debian packages or official releases. The avatar is the Immich logo.

DAppNode's Immich package (github.com/dappnode/DAppNodePackage-immich, no licence file) was read
for its update advice (do not move PostgreSQL to a new major automatically; Immich's `shm_size`);
no files were copied from it.

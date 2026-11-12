# Immich v3.4.0 in one container: the official server image (Debian 13) with
# the official machine-learning image's Python runtime copied in, PostgreSQL 17
# with pgvector and VectorChord 0.4.3 (the version Immich's own compose file
# uses), Valkey and nginx. Both Immich images are pinned by digest.
FROM --platform=linux/amd64 ghcr.io/immich-app/immich-machine-learning:v3.4.0@sha256:f4e7275c9fbd956ed7bccc738ac57890bcbd9f9c17844d2ea0b137e38a083454 AS ml

FROM --platform=linux/amd64 ghcr.io/immich-app/immich-server:v3.4.0@sha256:7b7b575029168bfb9eb901d868ce7dbfda0d7818e78aaace29b7b8a08cd4e7d5

ARG VCHORD_DEB=postgresql-17-vchord_0.4.3-1_amd64.deb
ARG VCHORD_SHA256=a4776ac7b1def6d4f02370227a214be50ec36c84d0af3469070120667215f4ae
# pgvector pinned: VectorChord 0.4.3 works with pgvector >=0.7, <0.9, so a
# newer pgvector must not slip into a rebuild unnoticed.
ARG PGVECTOR_VERSION=0.8.7-1.pgdg13+1

# PostgreSQL 17 + pgvector from the PostgreSQL project's Debian repository,
# which the image already uses for its PostgreSQL client tools (pgvector at
# a fixed version, see above). The image
# ships without the CA list apt needs for that https repository, so that is
# installed first from Debian.
RUN mv /etc/apt/sources.list.d/pgdg.list /tmp/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && mv /tmp/pgdg.list /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-17 "postgresql-17-pgvector=${PGVECTOR_VERSION}" valkey-server nginx-light openssl libgomp1 \
 && curl -fsSL -o /tmp/vchord.deb "https://github.com/tensorchord/VectorChord/releases/download/0.4.3/${VCHORD_DEB}" \
 && echo "${VCHORD_SHA256}  /tmp/vchord.deb" | sha256sum -c - \
 && apt-get install -y --no-install-recommends /tmp/vchord.deb \
 && rm -rf /tmp/vchord.deb /var/lib/apt/lists/* /etc/nginx/sites-enabled/default \
 && rm -rf /var/lib/postgresql/17

# Machine learning: Python 3.13, its packages and the immich_ml app, exactly
# as in the official machine-learning image (same Debian 13 base).
COPY --from=ml /usr/local/bin/python3.13 /usr/local/bin/python3.13
COPY --from=ml /usr/local/lib/python3.13 /usr/local/lib/python3.13
COPY --from=ml /usr/local/lib/libpython3.13.so.1.0 /usr/local/lib/libpython3.13.so.1.0
COPY --from=ml /opt/venv /opt/venv
COPY --from=ml /usr/src/immich_ml /usr/src/immich_ml
RUN ln -s python3.13 /usr/local/bin/python3 \
 && ln -s libpython3.13.so.1.0 /usr/local/lib/libpython3.13.so \
 && ldconfig \
 && cd /usr/src && PYTHONPATH=/usr/src /opt/venv/bin/python -c "import onnxruntime, immich_ml.main; print('machine learning ok, onnxruntime', onnxruntime.__version__)"

# HTTPS front: the *.my.ava.do certificate, refreshed at start from the box.
RUN mkdir -p /etc/avado/certs \
 && curl -fsS -o /etc/avado/certs/build.crt http://iso.ava.do/my.ava.do.crt \
 && curl -fsS -o /etc/avado/certs/build.key http://iso.ava.do/my.ava.do.key \
 && openssl x509 -in /etc/avado/certs/build.crt -noout -subject
COPY avado/ /etc/avado/
RUN chmod +x /etc/avado/*.sh

# Machine learning on the CPU, gentle on the box: one worker, two threads per
# model; models are downloaded on first use into the ml-cache volume and
# unloaded after 5 minutes without work. ORT_DISABLE_TELEMETRY: onnxruntime
# sends usage data to Microsoft unless this is set (Immich sets it itself
# since v3.3.6; set here as well so it can never be on).
ENV MACHINE_LEARNING_CACHE_FOLDER=/cache \
    TRANSFORMERS_CACHE=/cache \
    HF_HOME=/cache/hf-cache \
    DEVICE=cpu \
    MACHINE_LEARNING_MODEL_ARENA=false \
    MACHINE_LEARNING_WORKERS=1 \
    MACHINE_LEARNING_REQUEST_THREADS=2 \
    MACHINE_LEARNING_MODEL_INTRA_OP_THREADS=2 \
    MACHINE_LEARNING_MODEL_INTER_OP_THREADS=1 \
    MACHINE_LEARNING_MODEL_TTL=300 \
    ORT_DISABLE_TELEMETRY=1 \
    IMMICH_TRUSTED_PROXIES=127.0.0.1

ENTRYPOINT ["tini", "--", "/etc/avado/avado-start.sh"]
CMD ["/etc/avado/immich-run.sh"]

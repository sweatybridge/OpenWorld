FROM postgres:18-trixie AS harness

ARG TARGETARCH=amd64

ARG PG_DURABLE_VERSION=0.2.3
ARG PG_DURABLE_REPO=sweatybridge/pg_durable
ARG PG_DURABLE_SHA256=e247c3995ba3b8e1537f5f0a30ccef107054b3f0044d380e6c67fa18e4052370

ARG PG_SSH_VERSION=0.3.0
ARG PG_SSH_REPO=sweatybridge/pg_ssh
ARG PG_SSH_SHA256=0d641c13f50555b40c19d986745cc9114c3453bca3e7aac08c57b196147d7a84

ARG PG_FFMPEG_VERSION=0.3.4
ARG PG_FFMPEG_REPO=sweatybridge/pg_ffmpeg
# pg-ffmpeg-pg18_0.3.4-1.trixie_amd64.deb. The deb's Depends pull the FFmpeg 7.x
# runtime shared libs (libavcodec/libavformat/...) from Debian trixie, so no PPA
# and no shared_preload_libraries are required (pg_ffmpeg is SQL functions only).
ARG PG_FFMPEG_SHA256=b810e7dcf4713b25013284b7e6a2f906681fa47052b31df39ecc5ac6406f988d

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    # Download pg_durable package
    deb="pg-durable-postgresql-${PG_MAJOR}_${PG_DURABLE_VERSION}-1_${TARGETARCH}.deb"; \
    curl -fsSL \
      -o "/tmp/${deb}" \
      "https://github.com/${PG_DURABLE_REPO}/releases/download/v${PG_DURABLE_VERSION}/${deb}"; \
    echo "${PG_DURABLE_SHA256}  /tmp/${deb}" | sha256sum -c -; \
    # Download pg_ssh package
    deb="pg-ssh-pg${PG_MAJOR}_${PG_SSH_VERSION}-1.trixie_${TARGETARCH}.deb"; \
    curl -fsSL \
      -o "/tmp/${deb}" \
      "https://github.com/${PG_SSH_REPO}/releases/download/v${PG_SSH_VERSION}/${deb}"; \
    echo "${PG_SSH_SHA256}  /tmp/${deb}" | sha256sum -c -; \
    # Download pg_ffmpeg package (FFmpeg media processing; used by SEND_ATTACHMENT)
    deb="pg-ffmpeg-pg${PG_MAJOR}_${PG_FFMPEG_VERSION}-1.trixie_${TARGETARCH}.deb"; \
    curl -fsSL \
      -o "/tmp/${deb}" \
      "https://github.com/${PG_FFMPEG_REPO}/releases/download/v${PG_FFMPEG_VERSION}/${deb}"; \
    echo "${PG_FFMPEG_SHA256}  /tmp/${deb}" | sha256sum -c -; \
    # Install all extensions
    apt-get install -y --no-install-recommends /tmp/*.deb; \
    rm -f /tmp/*.deb; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    echo "shared_preload_libraries = 'pg_durable'" >> /usr/share/postgresql/postgresql.conf.sample; \
    # df's background workers (management + SQL-node executors) all draw from
    # max_worker_processes. With only the default 8, a loop blocked in
    # wait_for_completion (up to 120s) starves the pool and tool nodes queue
    # against execution_acquire_timeout (30s) — a 1ms tool call sat 46s. Raise
    # it so executors have headroom alongside the management workload.
    echo "max_worker_processes = 32" >> /usr/share/postgresql/postgresql.conf.sample; \
    # Orchestration runs over its own connection pools, separate from
    # max_worker_processes. The defaults (max_duroxide_connections=10,
    # max_management_connections=6) saturate once several agent loops run
    # concurrently — await_tool_calls' wait_for_completion holds pool capacity
    # for up to 120s, so tool activities queue, miss their 120s tool-call
    # timeout, and the instance is cancelled before the real work (e.g. an
    # execute-http) ever runs. Raise both to give executors headroom under
    # concurrent primary/subcons loops.
    echo "pg_durable.max_duroxide_connections = 32" >> /usr/share/postgresql/postgresql.conf.sample; \
    echo "pg_durable.max_management_connections = 12" >> /usr/share/postgresql/postgresql.conf.sample; \
    echo "pg_durable.database = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample; \
    echo "pg_durable.worker_role = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample

COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

FROM harness AS pgtap

# pgTAP extension + pg_prove (DBD::Pg) from the PostgreSQL apt repo.
RUN set -eux; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/ACCC4CF8.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/ACCC4CF8.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-${PG_MAJOR}-pgtap \
        libtap-parser-sourcehandler-pgtap-perl \
        libdbd-pg-perl; \
    rm -rf /var/lib/apt/lists/*

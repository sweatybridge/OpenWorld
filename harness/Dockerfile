FROM postgres:18-trixie AS harness

ARG TARGETARCH=amd64

ARG PG_DURABLE_VERSION=0.2.3
ARG PG_DURABLE_REPO=sweatybridge/pg_durable
ARG PG_DURABLE_SHA256=e247c3995ba3b8e1537f5f0a30ccef107054b3f0044d380e6c67fa18e4052370

ARG PG_SSH_VERSION=0.1.0
ARG PG_SSH_REPO=sweatybridge/pg_ssh
ARG PG_SSH_SHA256=eea4865d29486eb0265015d189bcfe0f9691a8d5a3b7d93468329c8430d9a39c

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl openssh-client; \
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
    # Install all extensions
    apt-get install -y --no-install-recommends /tmp/*.deb; \
    rm -f /tmp/*.deb; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    echo "shared_preload_libraries = 'pg_durable'" >> /usr/share/postgresql/postgresql.conf.sample; \
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

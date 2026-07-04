#!/bin/bash
# First-boot SSH host registration. Runs after 01-pg-ssh.sql (which CREATEs the
# extension and the ssh.hosts catalog) and before the 2x attobot init files.
#
# Generates an ed25519 keypair, inserts the private key + connection details into
# ssh.hosts (superuser-only), and prints the public key so the operator can paste
# it into the remote host's ~/.ssh/authorized_keys. All key handling happens here;
# the operator only sets host/user (env vars) and authorizes one public key.
#
# Activation: set ATTOBOT_SSH_HOST and ATTOBOT_SSH_USER. With either unset this is
# a no-op (the pgtap test image has no openssh-client and never reaches ssh-keygen).
#
# Sourcing-safe: the postgres entrypoint *sources* non-executable .sh init files,
# so this script must not use `set -e` or call `exit`/`return` -- either would
# abort the whole entrypoint. All control flow is plain if/else, and psql/ssh-keygen
# failures only print a message.

SSH_HOST="${ATTOBOT_SSH_HOST:-}"
SSH_USER="${ATTOBOT_SSH_USER:-}"

if [ -z "$SSH_HOST" ] || [ -z "$SSH_USER" ]; then
  echo "ssh-host: ATTOBOT_SSH_HOST/ATTOBOT_SSH_USER not set; skipping SSH host registration."
else
  HOST_NAME="${ATTOBOT_SSH_HOST_NAME:-default}"
  PORT="${ATTOBOT_SSH_PORT:-22}"
  FP="${ATTOBOT_SSH_HOST_KEY_FINGERPRINT:-}"

  KEYDIR="$(mktemp -d)"
  if ssh-keygen -t ed25519 -N '' -C "attobot-${HOST_NAME}" -f "${KEYDIR}/key" >/dev/null 2>&1; then
    PRIV="$(cat "${KEYDIR}/key")"
    PUB="$(cat "${KEYDIR}/key.pub")"
    shred -u "${KEYDIR}/key" "${KEYDIR}/key.pub" 2>/dev/null || rm -f "${KEYDIR}/key" "${KEYDIR}/key.pub"
    rmdir "${KEYDIR}" 2>/dev/null

    if psql -v ON_ERROR_STOP=1 \
            --set=host_name="${HOST_NAME}" \
            --set=host="${SSH_HOST}" \
            --set=port="${PORT}" \
            --set=user="${SSH_USER}" \
            --set=key="${PRIV}" \
            --set=fp="${FP}" <<'SQL'
INSERT INTO ssh.hosts (host_name, host, port, username, private_key, host_key_fingerprint)
VALUES (:'host_name', :'host', :'port'::integer, :'user', :'key', NULLIF(:'fp',''))
ON CONFLICT (host_name) DO NOTHING;
SQL
    then
      # Persist the public key on the PGDATA volume (owner: postgres) so it
      # survives log rotation. Strip anything path-shaped out of HOST_NAME.
      SAFE_NAME="$(printf '%s' "${HOST_NAME}" | tr -c 'A-Za-z0-9._-' '_')"
      PUBFILE="/var/lib/postgresql/ssh-${SAFE_NAME}.pub"
      if printf '%s\n' "${PUB}" > "${PUBFILE}" 2>/dev/null; then
        chmod 0644 "${PUBFILE}" 2>/dev/null
      fi

      echo "ssh-host: registered '${HOST_NAME}' -> ${SSH_USER}@${SSH_HOST}:${PORT}"
      echo "ssh-host: add this public key to the remote ~/.ssh/authorized_keys:"
      printf '%s\n' "${PUB}"
      if [ -f "${PUBFILE}" ]; then
        echo "ssh-host: (public key also at ${PUBFILE}; private key is in ssh.hosts only)"
      else
        echo "ssh-host: (private key stored in ssh.hosts only; temp key file shredded)"
      fi
    else
      echo "ssh-host: FAILED to register host '${HOST_NAME}' in ssh.hosts"
    fi
  else
    rm -rf "${KEYDIR}" 2>/dev/null
    echo "ssh-host: ssh-keygen failed; skipping SSH host registration."
  fi
fi

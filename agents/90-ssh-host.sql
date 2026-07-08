-- SSH host registration for the BASH tool. Mint an ed25519 keypair in-process
-- with ssh.keygen() (no ssh-keygen binary, no temp files; the private key goes
-- straight from keygen into ssh.hosts and never touches disk) and register the
-- host. Idempotent: ON CONFLICT DO UPDATE means re-runs are no-ops and the key
-- is never rotated. Skipped entirely when ATTOBOT_SSH_HOST/ATTOBOT_SSH_USER are
-- unset. The public key is RETURNING on every run and written to disk so it can
-- be volume mounted into the sshd container's ~/.ssh/authorized_keys.
--
-- MUST run last: \o below redirects all subsequent query output to the .pub
-- file, so any later file's results would be silently swallowed.
\t on
\pset format unaligned
\o ~/.ssh/id_ed25519.pub

INSERT INTO ssh.hosts (host_name, host, port, username, private_key, public_key, host_key_fingerprint)
SELECT :'ssh_host_name', :'ssh_host', :'ssh_port'::integer, :'ssh_user',
       private_key, public_key, NULLIF(:'ssh_fp', '')
  FROM ssh.keygen('ed25519', 'attobot-' || :'ssh_host_name')
 WHERE NULLIF(:'ssh_host', '') IS NOT NULL
   AND NULLIF(:'ssh_user', '') IS NOT NULL
 ON CONFLICT (host_name) DO UPDATE SET host_name = EXCLUDED.host_name
 RETURNING public_key;

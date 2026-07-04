-- pg_ssh exposes ssh.exec(host_name, command) for running remote commands over
-- SSH from inside PostgreSQL (returns TABLE(stdout bytea, stderr bytea,
-- exit_code int)), plus ssh.keygen() for in-memory keypair generation. The .so,
-- control, and install SQL are installed from the Debian package in the
-- Dockerfile; CREATE EXTENSION creates the ssh schema, the ssh.hosts catalog,
-- and the SECURITY DEFINER exec function plus the keygen function. There is no
-- shared_preload_libraries setting (no background worker).
CREATE EXTENSION IF NOT EXISTS pg_ssh;

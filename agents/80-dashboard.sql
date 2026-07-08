-- Password for the read-only attobot_dashboard DB role (created during first
-- boot by docker-entrypoint-initdb.d/41-dashboard-role.sql). Independent of the
-- agent definitions; run after the harness init SQL has created the role.
ALTER ROLE attobot_dashboard PASSWORD :'dashboard_db_password';

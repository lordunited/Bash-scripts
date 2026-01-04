-- 1. Create the table first (if not exists)
CREATE TABLE IF NOT EXISTS mariadb_logs (
    id SERIAL PRIMARY KEY,
    log_type VARCHAR(50),
    message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. Grant permissions ON THE TABLE NAME
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE mariadb_logs TO app_user;

-- 3. Grant permissions ON THE SEQUENCE (Required for the 'id' column)
GRANT USAGE, SELECT ON SEQUENCE mariadb_logs_id_seq TO app_user;

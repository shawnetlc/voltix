-- Run this once against production before deploying the updated backend.
ALTER TABLE voltix_sessions ADD COLUMN appVersion VARCHAR(64) NULL;

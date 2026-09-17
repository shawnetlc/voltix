-- Repairs the drift between drizzle/schema.ts and the live Voltix tables.
--
-- schema.ts declares createdAt/updatedAt with .defaultNow(); the deployed
-- tables carry no DEFAULT. Drizzle trusts the schema file and emits DEFAULT for
-- any timestamp a caller does not name, and MySQL in strict mode refuses it:
--
--   ER_NO_DEFAULT_FOR_FIELD: Field 'updatedAt' doesn't have a default value
--
-- Every INSERT that omits these columns therefore fails outright. Two confirmed
-- casualties so far: payment_transactions (PayFast renewals could not be
-- recorded) and voltix_pairing_codes ("Failed to generate code" on Link your
-- device, on both mobile and TV). The tables below are all those exposed to the
-- same fault.
--
-- Safe to re-run: MODIFY only rewrites the column definition, never a row, and
-- applying it twice is a no-op. Run against the `voltix` database.
--
-- Check one first if you want to see the drift for yourself:
--   SHOW CREATE TABLE `voltix_pairing_codes`;

-- users
ALTER TABLE `users` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `users` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- voltix_users
ALTER TABLE `voltix_users` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `voltix_users` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- servers
ALTER TABLE `servers` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;

-- voltix_sessions
ALTER TABLE `voltix_sessions` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;

-- subscriptions
ALTER TABLE `subscriptions` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `subscriptions` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- trials
ALTER TABLE `trials` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `trials` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- streaming_accounts
ALTER TABLE `streaming_accounts` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `streaming_accounts` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- payment_transactions
ALTER TABLE `payment_transactions` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `payment_transactions` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- settings
ALTER TABLE `settings` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- iptv_accounts
ALTER TABLE `iptv_accounts` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `iptv_accounts` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- iptv_favorites
ALTER TABLE `iptv_favorites` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;

-- iptv_watch_progress
ALTER TABLE `iptv_watch_progress` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- iptv_preferences
ALTER TABLE `iptv_preferences` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- voltix_pairing_codes
ALTER TABLE `voltix_pairing_codes` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `voltix_pairing_codes` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- voltix_user_settings
ALTER TABLE `voltix_user_settings` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- push_devices
ALTER TABLE `push_devices` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE `push_devices` MODIFY `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- push_notifications
ALTER TABLE `push_notifications` MODIFY `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;


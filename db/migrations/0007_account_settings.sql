-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- UP

-- Per-account, per-application preference store.
--
-- Settings are keyed by (account_id, app, key):
--   - account_id: the account id (matches iam.Account id)
--   - app:     the application scope; "core" is the default/general scope.
--              Applications are a future concept; `app` is a free string now
--              and gains an FK when applications become first-class.
--   - key:     the preference name, e.g. "timezone", "language".
--   - value:   typed JSON value (string, bool, number, object).
--
-- Settings are preference state, not domain documents: they are not
-- event-sourced. A preference change is not an auditable business event.
-- account_id carries no FK: account deletion does not cascade here — orphaned
-- preference rows are cleaned up by the callers that remove accounts.
CREATE TABLE account_settings (
  account_id      text    NOT NULL,
  app          text    NOT NULL,
  key          text    NOT NULL,
  value        jsonb   NOT NULL,
  updated_at   timestamp NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, app, key)
);

CREATE INDEX account_settings_account_idx ON account_settings(account_id);

-- DOWN

DROP TABLE IF EXISTS account_settings;

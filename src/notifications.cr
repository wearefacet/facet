# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# In-app notification store (Release 1.0).
#
# A notification is a per-account message in the `notifications` table
# (see `db/migrations/0009_notifications.sql`). It is not event-sourced:
# a notification is a derived side effect, not an auditable business
# event, so it lives outside `projections` / `mutations` — the same
# precedent `account_settings` sets. See `doc/backend/notifications.md`
# for the data model and the design decisions.
require "./notifications/send"
require "./notifications/queue"
require "./notifications/list"
require "./notifications/mark_read"
require "./notifications/invoke_action"
require "./notifications/routes"

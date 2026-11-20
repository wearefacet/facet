# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Runtime settings (`core.SystemSettings`) — the hot-changeable platform
# configuration. See `doc/backend/system-settings.md`.
require "./system_settings/spec"
require "./system_settings/service"
require "./system_settings/write_gate"
require "./system_settings/views"
require "./system_settings/mail_test"
require "./system_settings/routes"

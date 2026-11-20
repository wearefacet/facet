# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./settings/keys"
require "./settings/service"
require "./settings/routes"

module Facet
  # Namespace for account preferences (settings).
  #
  # Stores per-account, per-application preference state in the `account_settings`
  # table. Settings are NOT event-sourced: a preference change is not an
  # auditable business event (mirrors the `auth_secrets` precedent in the IAM
  # subsystem). The allowed `(app, key)` pairs and their value kinds are
  # declared in `Settings::Keys::REGISTRY` — unregistered keys are rejected.
  module Settings
    Log = ::Log.for("facet.settings")

    # The default/general application scope. Used for cross-application
    # preferences such as `timezone` and `language`.
    CORE_APP = "core"
  end
end

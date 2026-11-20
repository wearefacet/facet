# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module IAM
    # Qualified projection id of the seeded `iam.Roles.anonymous` role
    # (`data/seeds/iam.Roles/documents.yml`).
    #
    # A roleless account that can authenticate runs under this role (B-120):
    # the login, refresh, and bootstrap session paths elect it when the
    # account holds no usable role. The frontend detects the state from
    # `/Api/iam/me` — `available_roles` empty and `active_role` this id.
    ANONYMOUS_ROLE_ID = "iam.Roles.anonymous"
  end
end

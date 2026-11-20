# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "yaml"
require "../../src/iam"

# B-137 — the `iam.LoginEvent` seed enum must cover the live event
# vocabulary. `IAM::Helpers.write_login_event` writes whatever name its
# caller passes; a name outside the enum would fail the write (fail-silent
# audit loss — the helper logs and drops). This spec pins every name the
# auth/session code emits against the seed definition, so a new event name
# without a seed update fails here instead of silently losing audit rows.
LIVE_EVENT_NAMES = %w[
  login
  logout
  refresh
  refresh_reuse
  refresh_failed
  app_refresh
  mcp_refresh
  lockout
  password_reset_requested
  password_reset_used
  password_change
  password_login_denied
  invite_sent
  invite_accepted
  temp_password_generated
  mfa_enrolled
  mfa_enabled
  mfa_disabled
  consent_granted
  layer1_denied
  api_key_created
  api_key_revoked
  session_revoked
  app_sessions_revoked
  oidc_login
  oidc_provisioned
  oidc_denied
]

describe "iam.LoginEvent seed enum (B-137)" do
  it "carries every event name the code emits" do
    path = File.join(__DIR__, "..", "..", "data", "seeds", "iam.LoginEvent", "definition.yml")
    yaml = YAML.parse(File.read(path))
    values = yaml["fields"].as_h["event"]["values"].as_a.map(&.as_s)

    LIVE_EVENT_NAMES.each do |name|
      values.should contain(name)
    end
  end

  it "accepts every live name through the write path" do
    with_db do |db|
      Facet::Doctype::Seed.ensure_doctype(db, "iam", "LoginEvent")
      Facet::Doctype::DefinitionStore.cache.clear

      account_id = create_test_account(db, email: "enum@example.com")

      LIVE_EVENT_NAMES.each do |name|
        Facet::IAM::Helpers.write_login_event(db, account_id, name, "spec probe")
        stored = db.query_one?(
          "SELECT 1 FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' " \
          "AND content->>'event' = $1 AND deleted_at IS NULL",
          name, as: Int32)
        stored.should_not be_nil
      end
    end
  end
end

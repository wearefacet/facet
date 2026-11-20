# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/iam_helper"
require "../support/oidc_helper"
require "../../src/iam"
require "../../src/iam/auth_mode_cli"

# The `facet auth:mode` recovery command (QA finding B-135, with B-178):
# the CLI mutates `core.SystemSettings` outside the running servers, so
# the security gates must see the new mode on their next read without any
# fanout, and the command's event must land in the publisher queue for
# `CLI.dispatch` to flush. The policy gates read the document row
# directly (`SystemSettings.uncached_string_at`), so a warm, un-invalidated
# process cache cannot hide the write.
#
# The runner mirrors `AuthModeCLI.run`'s mutation one to one (same patch,
# same system principal) but leaves the suite's database pool alone —
# `AuthModeCLI.run` closes the pool on exit, which would kill the spec
# process's connections. The event-publication wiring it relies on is
# pinned by the publisher CLI specs.
module Facet
  describe IAM::AuthModeCLI do
    before_each do
      with_db do |db|
        Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
        # The `oidc_only` write gate requires one enabled provider document.
        # The provider doctype references `iam.Roles`; the seed domain and
        # the core doctypes the seeded roles scope over must exist first.
        ensure_seed_roles_with_dependencies(db)
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "OIDCProvider")
        seed_oidc_provider(db)
      end
      SystemSettings.reset_cache!
    end

    after_each do
      SystemSettings.reset_cache!
      Event::Publisher.discard
    end

    it "rejects a bad usage without touching the document" do
      IAM::AuthModeCLI.run([] of String).should eq(1)
      IAM::AuthModeCLI.run(["fast"]).should eq(1)
      IAM::AuthModeCLI.run(["hybrid", "extra"]).should eq(1)

      with_db do |db|
        IAM::Policy.auth_mode(db).should eq("hybrid")
      end
    end

    it "pins the mode so the gate reads it back without any fanout" do
      # Warm the cache exactly like a long-running server: the process has
      # already resolved the mode once. `IAM::Policy` reads uncached, so
      # the warm cache comes from the plain settings surface.
      with_db do |db|
        IAM::Policy.auth_mode(db).should eq("hybrid")
        SystemSettings.value_at(db, "iam.auth.mode").try(&.as_s)
        SystemSettings.stale?.should be_false

        result = Document::Update.call(
          db, "core", "SystemSettings", SystemSettings::DOC_ID,
          %({"iam": {"auth": {"mode": "oidc_only"}}}),
          RBAC::AuthContext.system,
        )
        result.should be_a(Document::Update::Result)
      end

      # The mutation buffered its fanout event — the flush fuel for
      # `CLI.dispatch`. In a real CLI run this queue dies with the process
      # unless it is published.
      Event::Publisher.pending_count.should be > 0

      # No fanout ran in the unit suite, so the process cache still holds
      # the stale mode — and the gate must not consult it. A refused
      # password login is the failure the QA drill hit (B-135).
      with_db do |db|
        IAM::Policy.oidc_only?(db).should be_true
        IAM::Policy.auth_mode(db).should eq("oidc_only")
      end
    end

    it "switches back to hybrid and the gate follows" do
      with_db do |db|
        Document::Update.call(
          db, "core", "SystemSettings", SystemSettings::DOC_ID,
          %({"iam": {"auth": {"mode": "oidc_only"}}}),
          RBAC::AuthContext.system,
        ).should be_a(Document::Update::Result)
        IAM::Policy.oidc_only?(db).should be_true

        Document::Update.call(
          db, "core", "SystemSettings", SystemSettings::DOC_ID,
          %({"iam": {"auth": {"mode": "hybrid"}}}),
          RBAC::AuthContext.system,
        ).should be_a(Document::Update::Result)
        IAM::Policy.oidc_only?(db).should be_false
      end
    end
  end
end

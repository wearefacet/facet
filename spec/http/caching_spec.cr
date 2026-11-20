# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/caching"

# Unit coverage for the collection-ETag role fingerprint. The HTTP-level
# behaviour (200/304 round-trips, cross-account isolation) is covered by
# `etag_spec.cr`; these examples pin the per-variant fingerprint format.
describe "HTTP::Caching.role_fingerprint" do
  it "fingerprints the system bypass as system:<account_id>" do
    Facet::HTTP::Caching.role_fingerprint(Facet::RBAC::AuthContext.system).should eq("system:system")
  end

  it "keeps an attributed system caller's account id" do
    ctx = Facet::RBAC::AuthContext.system("assistant-account")
    Facet::HTTP::Caching.role_fingerprint(ctx).should eq("system:assistant-account")
  end

  it "fingerprints a real principal as <account_id>:<role_id>" do
    role = Facet::RBAC::ActiveRole.new(
      role_id: "editor",
      visible_tags: Set{"default"},
      permissions: [] of Facet::RBAC::Permission,
    )
    ctx = Facet::RBAC::AuthContext.authenticated("account_1", role)
    Facet::HTTP::Caching.role_fingerprint(ctx).should eq("account_1:editor")
  end

  it "fingerprints a preview principal as preview:<account_id>:<preview_domain>" do
    ctx = Facet::RBAC::AuthContext.preview("account_1", "_abc")
    Facet::HTTP::Caching.role_fingerprint(ctx).should eq("preview:account_1:_abc")
  end

  it "separates preview principals bound to different drafts" do
    a = Facet::HTTP::Caching.role_fingerprint(Facet::RBAC::AuthContext.preview("account_1", "_abc"))
    b = Facet::HTTP::Caching.role_fingerprint(Facet::RBAC::AuthContext.preview("account_1", "_def"))
    a.should_not eq(b)
  end
end

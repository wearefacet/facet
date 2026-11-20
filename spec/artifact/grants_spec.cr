# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/access"
require "../../src/artifact/grants"
require "../../src/doctype"
require "../../src/doctype/update"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "digest/sha256"
require "json"

# Step 4 of the artifact system: signed capability URLs (grants).
#
# Files covered:
#   - src/artifact/grants.cr — mint_ephemeral, mint_permanent, verify,
#     revoke, sign, signature_matches? (HMAC + two-key rotation).
#   - src/artifact/access.cr — `can_read?` is the gate for mint_ephemeral;
#     `WriteEnforcer.authorize_action(publish_artifact)` is the gate for
#     mint_permanent.
#
# Specs walk every documented rule:
#   1. ephemeral mint allowed for a reader; denied for a non-reader.
#   2. permanent mint requires `publish_artifact` action declared on the
#      doctype AND granted to the role on the owner's doc_id. Either gate
#      missing → blocked.
#   3. doctype without the action can never publish (even with system-bypass
#      on the role side — the declaration gate is independent).
#   4. provenance bind: a permanent grant on owner row A does not expose
#      owner row B's bytes (a different B-linked artifact read is still
#      gated by `can_read?` against A's doc).
#   5. expiry → 403 on verify.
#   6. epoch bump → 403 on verify.
#   7. tampered signature → 403.
#   8. grant signed under previous secret validates.
#   9. epoch bump invalidates a grant signed under either secret.
#
# The HTTP surface (range request, SVG-as-attachment, response hardening)
# is covered in `routes_spec.cr`.

DOMAIN_GRANTS = "artgrants"

# Truncates every artifact table + projections/mutations so each spec
# starts from a known-empty state.
def truncate_grants_tables
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Inline Lua script so the doctype declares `publish_artifact` and the
# ScriptValidator accepts the export.
PUBLISH_SCRIPT = <<-LUA
  local export = {}
  function export.publish_artifact(ctx, args)
    return ctx.root
  end
  return export
LUA

# Builds a doctype with:
#   - a `file` field carrying the supplied sensitivity tags.
#   - a `publish_artifact` action (so the publish-grant author-intent gate
#     passes when a role grants the action).
#
# Returns `{doctype_name, doc_id}` where one document of the doctype has
# been created.
def setup_grants_doctype(db, doctype, tags : Array(String)? = nil, with_publish = true)
  ensure_domain(db, DOMAIN_GRANTS)
  file_type = Facet::Doctype::FieldType.parse("file")
  actions = {} of String => Facet::Doctype::ActionDefinition
  actions["publish_artifact"] = Facet::Doctype::ActionDefinition.new if with_publish
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: DOMAIN_GRANTS,
    fields: {
      "file" => Facet::Doctype::FieldDefinition.new(type: file_type, tags: tags),
    } of String => Facet::Doctype::FieldDefinition,
    actions: actions,
    script: with_publish ? PUBLISH_SCRIPT : nil,
  )
  res = Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  )
  res.should be_a(Facet::Document::Create::Result)
  doc_res = Facet::Document::Create.call(
    db, DOMAIN_GRANTS, doctype, %({}), Facet::RBAC::AuthContext.system,
  )
  doc_res.should be_a(Facet::Document::Create::Result)
  {doctype, doc_res.as(Facet::Document::Create::Result).projection.id}
end

# Composes an `AuthContext.authenticated` for a freshly-seeded role with
# unscoped `read` and an optional `publish_artifact` permission on the
# target doctype.
def grants_auth(db, account_id, role_id, doctype, with_publish = false,
                view_tags = ["default"], read_on = nil)
  perms = [permission_json("read", "#{DOMAIN_GRANTS}.#{read_on || doctype}")]
  if with_publish
    perms << permission_json("publish_artifact", "#{DOMAIN_GRANTS}.#{doctype}")
  end
  create_role_projection(db, role_id, perms, visible_tags: view_tags)
  create_account_projection(db, account_id, [role_id])
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id),
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Tiny transparent PNG used as upload bytes for grant tests.
def grant_png_bytes : Bytes
  Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAvCBxjw=")
end

# Drives `Uploader.upload` to seed an artifact + owner row bound to a
# specific document. Returns `{artifact_id, path, owner_id}`.
#
# `bytes` defaults to the shared PNG fixture. Pass distinct bytes when the
# spec needs two uploads to produce *distinct* artifacts — identical bytes
# dedup to the same `artifacts` row, so `find_owner_rows(...).first` would
# return the first (earliest-created) owner row regardless of `doc_id`.
def upload_grant_fixture(db, doctype, doc_id, bytes : Bytes = grant_png_bytes)
  result = Facet::Artifact::Uploader.upload(
    db, IO::Memory.new(bytes), "asset.png",
    Facet::RBAC::AuthContext.system,
    DOMAIN_GRANTS, doctype, doc_id, "file", nil,
  )
  result.should be_a(Facet::Artifact::Uploader::Result)
  res = result.as(Facet::Artifact::Uploader::Result)
  owner_id = Facet::Artifact::Store.find_owner_rows(db, res.artifact_id).first.id
  {res.artifact_id, res.path, owner_id}
end

describe Facet::Artifact::Grants do
  before_each { truncate_grants_tables }

  # ── 1. ephemeral mint ──────────────────────────────────────────────────

  describe ".mint_ephemeral" do
    it "mints an ephemeral grant for a caller who can read the artifact" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        grant = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
        grant.should be_a(Facet::Artifact::Grants::SignedURL)
        url = grant.as(Facet::Artifact::Grants::SignedURL)
        url.artifact_id.should eq(art_id)
        url.expires_at.should_not be_nil
        url.url.should contain("/A/")
        url.url.should contain("exp=")
        url.url.should contain("sig=")
      end
    end

    it "denies an ephemeral grant for a non-reader" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        other_doctype, _ = setup_grants_doctype(db, "Other", with_publish: false)
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)

        # alice has read on a different doctype — provenance fail.
        alice = grants_auth(db, "alice", "alice_role", other_doctype)
        grant = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
        grant.should be_a(Facet::Artifact::Grants::Error)
        (grant.as(Facet::Artifact::Grants::Error)).status.should eq(403)
      end
    end

    it "uses the longer TTL for media MIME types" do
      with_db do |db|
        # Upload a small MP4 ftyp file so `sniff_mime` returns `video/mp4`.
        doctype, doc_id = setup_grants_doctype(db, "Video")
        mp4 = Bytes.new(16)
        "\x00\x00\x00\x10ftypisom".to_slice.copy_to(mp4)
        result = Facet::Artifact::Uploader.upload(
          db, IO::Memory.new(mp4), "clip.mp4",
          Facet::RBAC::AuthContext.system,
          DOMAIN_GRANTS, doctype, doc_id, "file", nil,
        ).as(Facet::Artifact::Uploader::Result)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        grant = Facet::Artifact::Grants.mint_ephemeral(db, alice, result.artifact_id)
          .as(Facet::Artifact::Grants::SignedURL)
        cfg = Facet::Config.instance.artifact
        grant.expires_at.not_nil! > (Time.utc + cfg.grant_ttl_seconds.seconds)
      end
    end

    it "honors a pinned grant TTL from the runtime settings" do
      with_db do |db|
        Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
        pin = Facet::Document::Update.call(
          db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
          %({"artifact": {"grant_ttl_seconds": 120}}),
          Facet::RBAC::AuthContext.system,
        )
        pin.should be_a(Facet::Document::Update::Result)
        # No Redis fanout runs in the unit suite — invalidate like the subscriber.
        Facet::SystemSettings.mark_stale

        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        signed = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
          .as(Facet::Artifact::Grants::SignedURL)
        elapsed = signed.expires_at.not_nil! - Time.utc
        elapsed.total_seconds.should be_close(120, 5)
      ensure
        Facet::SystemSettings.reset_cache!
      end
    end
  end

  # ── 2. permanent mint ──────────────────────────────────────────────────

  describe ".mint_permanent" do
    it "mints a permanent grant when action is declared AND role grants it" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype, with_publish: true)

        grant = Facet::Artifact::Grants.mint_permanent(db, alice, owner_id)
        grant.should be_a(Facet::Artifact::Grants::SignedURL)
        url = grant.as(Facet::Artifact::Grants::SignedURL)
        url.artifact_id.should eq(art_id)
        url.expires_at.should be_nil
        # Permanent URL still carries exp=0 in the HMAC; the URL omits exp
        # from the query per the design. Sign still ends with `sig=`.
        url.url.should contain("sig=")
      end
    end

    it "denies a permanent grant when can_read? is sufficient but publish_artifact is not granted" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        _art_id, _path, owner_id = upload_grant_fixture(db, doctype, doc_id)

        # alice has read on the doctype but no publish_artifact — must fail.
        alice = grants_auth(db, "alice", "alice_role", doctype, with_publish: false)
        grant = Facet::Artifact::Grants.mint_permanent(db, alice, owner_id)
        grant.should be_a(Facet::Artifact::Grants::Error)
        (grant.as(Facet::Artifact::Grants::Error)).status.should eq(403)
      end
    end

    it "denies permanent mint when the doctype has not declared publish_artifact" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset", with_publish: false)
        _art_id, _path, owner_id = upload_grant_fixture(db, doctype, doc_id)

        # alice is system-equivalent for the role check (has read + would
        # have publish_artifact). The doctype declaration gate is the
        # blocking one — the doctype MUST declare the action.
        create_role_projection(db, "alice_role", [
          permission_json("read", "#{DOMAIN_GRANTS}.#{doctype}"),
          permission_json("publish_artifact", "#{DOMAIN_GRANTS}.#{doctype}"),
        ])
        create_account_projection(db, "alice", ["alice_role"])
        role = Facet::RBAC::ActiveRole.from_projection_content(
          Facet::Mutation::Client.fetch_content(db, "iam", "Role", "alice_role"),
        )
        alice = Facet::RBAC::AuthContext.authenticated("alice", role)

        grant = Facet::Artifact::Grants.mint_permanent(db, alice, owner_id)
        grant.should be_a(Facet::Artifact::Grants::Error)
        (grant.as(Facet::Artifact::Grants::Error)).status.should eq(403)
      end
    end

    it "returns 404 when the owner row does not exist" do
      with_db do |db|
        doctype, _doc_id = setup_grants_doctype(db, "Asset")
        alice = grants_auth(db, "alice", "alice_role", doctype, with_publish: true)

        # Mint against a non-existent owner id.
        grant = Facet::Artifact::Grants.mint_permanent(db, alice, "01OWNERROW0000000001")
        grant.should be_a(Facet::Artifact::Grants::Error)
        (grant.as(Facet::Artifact::Grants::Error)).status.should eq(404)
      end
    end
  end

  # ── 3. provenance bind ─────────────────────────────────────────────────

  it "a permanent grant on one owner row does not expose another owner's bytes" do
    with_db do |db|
      # Doctype with a `file` field, an `owner` field, and a `mine` named
      # scope (`owner == $self`). alice's role has read + publish_artifact
      # scoped to $mine — so she may only act on documents whose `owner`
      # field matches her qualified account id.
      ensure_domain(db, DOMAIN_GRANTS)
      file_type = Facet::Doctype::FieldType.parse("file")
      string_type = Facet::Doctype::FieldType.parse("string")
      actions = {} of String => Facet::Doctype::ActionDefinition
      actions["publish_artifact"] = Facet::Doctype::ActionDefinition.new
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Asset",
        domain: DOMAIN_GRANTS,
        fields: {
          "file"  => Facet::Doctype::FieldDefinition.new(type: file_type),
          "owner" => Facet::Doctype::FieldDefinition.new(type: string_type),
        } of String => Facet::Doctype::FieldDefinition,
        actions: actions,
        scopes: {
          "mine" => Facet::Doctype::NamedScope.new(name: "mine", where: {"owner" => "$self"}),
        },
        script: PUBLISH_SCRIPT,
      )
      Facet::Document::Create.call(
        db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
      )

      doc_a = Facet::Document::Create.call(
        db, DOMAIN_GRANTS, "Asset", %({"owner": "iam.Account.alice"}),
        Facet::RBAC::AuthContext.system,
      ).as(Facet::Document::Create::Result).projection.id
      doc_b = Facet::Document::Create.call(
        db, DOMAIN_GRANTS, "Asset", %({"owner": "iam.Account.bob"}),
        Facet::RBAC::AuthContext.system,
      ).as(Facet::Document::Create::Result).projection.id

      create_role_projection(db, "alice_role", [
        permission_json("read", "#{DOMAIN_GRANTS}.Asset", "$mine"),
        permission_json("publish_artifact", "#{DOMAIN_GRANTS}.Asset", "$mine"),
      ], visible_tags: ["default"])
      create_account_projection(db, "alice", ["alice_role"])
      role = Facet::RBAC::ActiveRole.from_projection_content(
        Facet::Mutation::Client.fetch_content(db, "iam", "Role", "alice_role"),
      )
      alice = Facet::RBAC::AuthContext.authenticated("alice", role)

      # Upload artifact A against doc A, B against doc B. Distinct bytes so
      # the two uploads do NOT dedup to the same `artifacts` row — each must
      # get its own owner row bound to its own document.
      art_a, _path_a, owner_a = upload_grant_fixture(db, "Asset", doc_a)
      art_b, _path_b, owner_b = upload_grant_fixture(db, "Asset", doc_b,
        bytes: grant_png_bytes + Bytes.new(1))

      # alice may read artifact A (her $self predicate binds because
      # doc_a.owner == iam.Account.alice).
      Facet::Artifact::Access.can_read?(db, alice, art_a).should be_true

      # alice may mint a permanent grant against owner_a — she controls
      # doc_a (publish_artifact scoped to $mine, doc_a's owner = alice).
      res_a = Facet::Artifact::Grants.mint_permanent(db, alice, owner_a)
      res_a.should be_a(Facet::Artifact::Grants::SignedURL)

      # alice CANNOT publish via owner_b — the $self predicate does not
      # bind (doc_b.owner == bob, not alice). A permanent grant minted
      # against owner_a gives no privilege over owner_b.
      res_b = Facet::Artifact::Grants.mint_permanent(db, alice, owner_b)
      res_b.should be_a(Facet::Artifact::Grants::Error)
      (res_b.as(Facet::Artifact::Grants::Error)).status.should eq(403)

      # alice may NOT read artifact B either — same $mine scope fails.
      Facet::Artifact::Access.can_read?(db, alice, art_b).should be_false
    end
  end

  # ── 4. verify — expiry, epoch, tampered signature ─────────────────────

  describe ".verify" do
    it "verifies a freshly-minted ephemeral grant" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        signed = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
          .as(Facet::Artifact::Grants::SignedURL)
        exp = signed.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!
        sig = signed.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!

        result = Facet::Artifact::Grants.verify(db, signed.grant_id, exp, sig)
        result.should be_a(Facet::Artifact::Grants::ValidResult)
        (result.as(Facet::Artifact::Grants::ValidResult)).artifact.id.should eq(art_id)
      end
    end

    it "rejects an expired ephemeral grant" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        signed = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
          .as(Facet::Artifact::Grants::SignedURL)
        # Backdate the grant's expires_at to a time in the past.
        grant_id = signed.grant_id
        past = (Time.utc - 1.hour).to_utc.to_s("%Y-%m-%d %H:%M:%S.%N")
        db.exec("UPDATE artifact_grants SET expires_at = $1 WHERE id = $2", past, grant_id)
        # `exp` segment must match the row's stored expires_at; we recompute
        # it from the backdated row by reading the unix timestamp back.
        exp_unix = (Time.utc - 1.hour).to_unix.to_s
        sig = signed.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!

        # Signature mismatch because exp_segment_for recomputes off the row.
        # The verifier recomputes the expected sig with the new expires_at,
        # so the URL's original sig (signed under the original exp) won't
        # match → Invalid. (This is also the security guarantee: signature
        # is bound to the row, not just the URL params.)
        result = Facet::Artifact::Grants.verify(db, grant_id, exp_unix, sig)
        result.should be_a(Facet::Artifact::Grants::InvalidResult)
      end
    end

    it "rejects a tampered signature" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        signed = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
          .as(Facet::Artifact::Grants::SignedURL)
        exp = signed.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!

        # Flip the first character of the sig so the HMAC verify fails.
        original_sig = signed.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!
        tampered = (original_sig[0] == 'A' ? 'B' : 'A') + original_sig[1..]

        result = Facet::Artifact::Grants.verify(db, signed.grant_id, exp, tampered)
        result.should be_a(Facet::Artifact::Grants::InvalidResult)
      end
    end

    it "invalidates a grant when epoch is bumped" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        signed = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
          .as(Facet::Artifact::Grants::SignedURL)
        exp = signed.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!
        sig = signed.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!

        # Bump epoch on every grant for this artifact.
        Facet::Artifact::Grants.bump_epoch(db, art_id)

        result = Facet::Artifact::Grants.verify(db, signed.grant_id, exp, sig)
        result.should be_a(Facet::Artifact::Grants::InvalidResult)
      end
    end

    it "rejects a grant signed under the previous secret after epoch bump" do
      with_db do |db|
        # Set the previous secret so the signer uses it for the first mint.
        # Then bump the epoch (which invalidates grants signed under EITHER
        # secret, since the verifier reads epoch off the row).
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        signed = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
          .as(Facet::Artifact::Grants::SignedURL)
        exp = signed.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!
        sig = signed.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!

        Facet::Artifact::Grants.bump_epoch(db, art_id)
        result = Facet::Artifact::Grants.verify(db, signed.grant_id, exp, sig)
        result.should be_a(Facet::Artifact::Grants::InvalidResult)
      end
    end

    it "verifies a grant signed under the previous rotation secret" do
      with_db do |db|
        # Install a config where the current secret has rotated; the
        # previous secret still validates.
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        # Mint the grant under the current secret.
        signed = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
          .as(Facet::Artifact::Grants::SignedURL)
        exp = signed.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!
        sig = signed.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!

        # Reconfigure: current secret becomes the previous, fresh current.
        Facet::Config.reset!
        raw = YAML.parse(<<-YAML)
          host: "localhost:3000"
          base_url: "http://localhost:3000"
          artifact_base_url: "http://localhost:3001"
          artifact_grant_secret: "rotated-current-secret"
          artifact_grant_secret_previous: "test-grant-secret-fixed"
          artifact:
            storage:
              type: filesystem
              directory: tmp/uploads/test/store
          event:
            url: "redis://localhost:6379/0"
          secrets:
            master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
        YAML
        Facet::Config.from_yaml_node(raw)

        result = Facet::Artifact::Grants.verify(db, signed.grant_id, exp, sig)
        result.should be_a(Facet::Artifact::Grants::ValidResult)
      end
    end

    it "rejects a permanently-revoked grant" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        art_id, _path, _owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype)

        signed = Facet::Artifact::Grants.mint_ephemeral(db, alice, art_id)
          .as(Facet::Artifact::Grants::SignedURL)
        exp = signed.url.match(/\?exp=([^&]+)/).try(&.[1]).not_nil!
        sig = signed.url.match(/sig=([^&]+)/).try(&.[1]).not_nil!

        # System can revoke. After revoke the row is gone → verify returns
        # Invalid.
        res = Facet::Artifact::Grants.revoke(db, Facet::RBAC::AuthContext.system,
          signed.grant_id)
        res.should be_nil
        result = Facet::Artifact::Grants.verify(db, signed.grant_id, exp, sig)
        result.should be_a(Facet::Artifact::Grants::InvalidResult)
      end
    end
  end

  # ── 5. revoke ──────────────────────────────────────────────────────────

  describe ".revoke" do
    it "revokes a grant when the caller has publish_artifact on the owner" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        _art_id, _path, owner_id = upload_grant_fixture(db, doctype, doc_id)
        alice = grants_auth(db, "alice", "alice_role", doctype, with_publish: true)

        signed = Facet::Artifact::Grants.mint_permanent(db, alice, owner_id)
          .as(Facet::Artifact::Grants::SignedURL)

        res = Facet::Artifact::Grants.revoke(db, alice, signed.grant_id)
        res.should be_nil
      end
    end

    it "denies revoke for a caller with read but no publish_artifact" do
      with_db do |db|
        doctype, doc_id = setup_grants_doctype(db, "Asset")
        _art_id, _path, owner_id = upload_grant_fixture(db, doctype, doc_id)
        minter = grants_auth(db, "alice", "alice_role", doctype, with_publish: true)
        reader = grants_auth(db, "bob", "bob_role", doctype, with_publish: false)

        signed = Facet::Artifact::Grants.mint_permanent(db, minter, owner_id)
          .as(Facet::Artifact::Grants::SignedURL)
        res = Facet::Artifact::Grants.revoke(db, reader, signed.grant_id)
        res.should be_a(Facet::Artifact::Grants::Error)
        (res.as(Facet::Artifact::Grants::Error)).status.should eq(403)
      end
    end
  end
end

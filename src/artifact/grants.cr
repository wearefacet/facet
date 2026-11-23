# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "base64"
require "json"
require "openssl/hmac"
require "pg"
require "../config"
require "../database"
require "../util/crypto"
require "../util/script_helpers"
require "../rbac"
require "../doctype/definition_store"
require "../rbac/write_enforcer"
require "./store"
require "./access"
require "./uploader"
require "../system_settings/service"

module Facet
  module Artifact
    # Signed capability URLs — the only path artifact bytes reach an
    # unauthenticated caller. Browsers cannot send a DPoP proof, so an
    # authenticated caller (document reader, mutation RPC) exchanges their
    # credentials for a short-lived signed URL served from a separate
    # origin (`artifact_base_url`) that has no cookies and no CORS.
    #
    # Two kinds:
    #
    # - `ephemeral` — minted against an `artifact_id` for callers who can
    #   already `Access.can_read?` the artifact. Short TTL: 1h for
    #   documents / images, 6h for `audio/*` and `video/*` so a seek
    #   mid-playback doesn't hit an expired URL.
    #
    # - `permanent` — minted against an `owner_id` (a provenance document),
    #   requiring the `publish_artifact` named action on `{domain}.{doc_type}`
    #   scoped to `doc_id`. The doctype must declare `publish_artifact` in
    #   its `actions` map. Never expires; revoked via `delete`.
    #
    # Signature format:
    #
    # ```
    # sig = HMAC-SHA256(secret, "{grant_id}|{artifact_id}|{exp}|{epoch}")
    # url = {artifact_base_url}/A/{grant_id}?exp={unix}&sig={b64url}
    # ```
    #
    # The `artifact_id` and `epoch` are read from the row, NEVER from the
    # URL — that prevents substitution of the artifact a grant was minted
    # against and lifts `epoch` invalidation in O(1). Two-key rotation is
    # supported (`artifact_grant_secret_previous`); a grant signed under
    # either secret validates, but a bumped `epoch` invalidates both.
    module Grants
      Log = ::Log.for("facet.artifact.grants")

      # ── Records ────────────────────────────────────────────────────────

      # An `artifact_grants` row.
      record Grant,
        id : String,
        artifact_id : String,
        owner_id : String,
        kind : String,
        expires_at : Time?,
        epoch : Int32,
        created_by : String,
        created_at : Time

      # A signed URL ready to embed in a JSON response or hand to a client.
      # `expires_at` is `nil` for permanent grants (no `exp` in the URL).
      record SignedURL,
        grant_id : String,
        artifact_id : String,
        expires_at : Time?,
        epoch : Int32,
        url : String

      # Result of `verify` — distinguishes "valid" from "invalid" so the
      # serve route can map each case to its own status code. The
      # `Valid` variant carries the artifacts row the bytes belong to.
      struct ValidResult
        getter grant : Grant
        getter artifact : Store::Artifact

        def initialize(@grant : Grant, @artifact : Store::Artifact)
        end

        def valid? : Bool
          true
        end
      end

      struct InvalidResult
        getter reason : String

        def initialize(@reason : String = "invalid signature")
        end

        def valid? : Bool
          false
        end
      end

      # Convenience union — `verify` returns one of the two variants.
      alias VerifyResult = ValidResult | InvalidResult

      # Error type returned by the mint / revoke paths. The status field
      # is an HTTP status code; the message the JSON body.
      record Error, status : Int32, message : String

      # ── Constants ──────────────────────────────────────────────────────

      # Permanent-grant sentinel used in the HMAC's `exp` segment so a
      # verifier computes the signature either for `unix` seconds
      # (ephemeral) or this literal (permanent) — same code path.
      PERMANENT_EXP_TOKEN = "0"

      EPHEMERAL_KIND = "ephemeral"
      PERMANENT_KIND = "permanent"

      # Action name authors declare on a doctype whose attachments may be
      # published to the internet — see `doc/backend/rbac.md` → Named-action
      # conventions.
      PUBLISH_ACTION_NAME = "publish_artifact"

      # Operator action that authorizes revocation from the artifact admin
      # surface (`GET /Api/Artifacts`). Artifacts are not RBAC doctype
      # targets — the ACL is provenance-based — so the permission carries no
      # scope semantics: only the wildcard target `*.*` is meaningful, and
      # the check is deny-only-`Denied`, the same rule the other operator
      # surfaces apply (`Index::List`, `Audit::List`).
      REVOKE_ACTION = "revoke"

      # Operator action that authorizes an operator-path download through
      # the gateway — deny-only-`Denied`, the same rule the other operator
      # surfaces apply (`Index::List`, `Audit::List`). See
      # `doc/backend/artifact.md` → Download gateway.
      DOWNLOAD_ACTION = "download"

      # ── Mint ────────────────────────────────────────────────────────────

      # Mints an ephemeral grant for `artifact_id`. The caller must be able
      # to read the artifact (see `Artifact::Access.can_read?`). Returns a
      # signed URL whose TTL is keyed off the artifact's MIME type:
      #
      #   - 60s for documents / images (the default).
      #   - 21_600s (6 h) for `audio/*` and `video/*` so a seek mid-playback
      #     doesn't hit an expired URL.
      def self.mint_ephemeral(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        artifact_id : String,
      ) : SignedURL | Error
        # 1. Reads-allowed gate.
        unless ::Facet::Artifact::Access.can_read?(db, auth_context, artifact_id)
          return Error.new(403, "Forbidden")
        end

        # 2. Load the artifact so we can derive the TTL from the MIME and
        #    so the grant row references the live `path` for serving.
        artifact = load_live_artifact(db, artifact_id)
        return artifact if artifact.is_a?(Error)

        # 3. Pick the owner row the grant is minted against. Provenance
        #    binds the grant — the first readable owner is chosen. We need
        #    `owner_id` because the grant row references it (and so the
        #    serve route can attribute the bytes back to a provenance if
        #    audit needs it).
        owner = pick_readable_owner(db, auth_context, artifact_id)
        return Error.new(403, "Forbidden") unless owner

        # 4-5. Compute the media-aware TTL, insert, and sign — shared tail
        #      with the app-origin path.
        insert_and_sign_ephemeral(
          db, artifact_id, owner.id, auth_context.account_id, artifact.mime_type,
        )
      end

      # Mints an ephemeral grant attributed to an anonymous app-origin
      # request. The caller has already authenticated the request via
      # `Access.can_read_for_app?` (origin check + app grant ceiling) — this
      # method only writes the grant row and signs the URL.
      #
      # `created_by` carries the sentinel `"app:<app_id>"` so audit attribution
      # records the app, not a user. There is no `AuthContext` here: the
      # app-origin caller proved their origin against the app's
      # `allowed_origins`, but no account id is available.
      def self.mint_ephemeral_for_app(
        db : DB::Connection,
        app_id : String,
        app_scope : ::Facet::RBAC::AppScope,
        artifact_id : String,
      ) : SignedURL | Error
        # 1. Reads-allowed gate (app grant ceiling). The route has already
        #    called `can_read_for_app?`, but `mint_ephemeral_for_app` is a
        #    public surface; re-check so a future caller cannot bypass.
        unless ::Facet::Artifact::Access.can_read_for_app?(db, app_scope, artifact_id)
          return Error.new(403, "Forbidden")
        end

        # 2. Load the artifact — derive the TTL from the MIME and reference
        #    the live `path` for serving.
        artifact = load_live_artifact(db, artifact_id)
        return artifact if artifact.is_a?(Error)

        # 3. Pick the owner row the grant is minted against — the first
        #    owner row the app grant ceiling covers. Mirrors
        #    `pick_readable_owner` but against the app grant set instead of a
        #    user role.
        owner = pick_owner_for_app(db, app_scope, artifact_id)
        return Error.new(403, "Forbidden") unless owner

        # 4-5. Compute the media-aware TTL, insert, and sign. Audit
        #      attribution is the app sentinel.
        insert_and_sign_ephemeral(
          db, artifact_id, owner.id, "app:#{app_id}", artifact.mime_type,
        )
      end

      # Mints an ephemeral grant on the operator path — the download
      # gateway's fallback when provenance (`Access.can_read?`) does not
      # match but the caller holds the `download *.*` operator action. The
      # artifact admin page lists every row of the store to that action's
      # holders; this lets the same role inspect the bytes behind the
      # listing — including account-scoped standalone uploads and artifacts
      # whose provenance documents are gone, the two cases provenance can
      # never cover.
      #
      # The gate is re-checked here (deny-only-`Denied`) so a future caller
      # cannot bypass by calling `Grants` directly — the same discipline
      # `mint_ephemeral_for_app` applies. The grant binds to the artifact's
      # first owner row of any kind (the `_account` standalone-upload row
      # qualifies); an artifact with no owner rows at all cannot bind a
      # grant and answers `403` — such rows are prune-eligible debris; the
      # operator purges them instead of downloading.
      def self.mint_ephemeral_for_operator(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        artifact_id : String,
      ) : SignedURL | Error
        result = auth_context.can?(DOWNLOAD_ACTION, "*.*")
        return Error.new(403, "Forbidden") if result.is_a?(::Facet::RBAC::CanResult::Denied)

        artifact = load_live_artifact(db, artifact_id)
        return artifact if artifact.is_a?(Error)

        owner = pick_first_owner(db, artifact_id)
        return Error.new(403, "Forbidden") unless owner

        insert_and_sign_ephemeral(
          db, artifact_id, owner.id, auth_context.account_id, artifact.mime_type,
        )
      end

      # Mints a permanent grant against an owner row. The caller must have
      # the `publish_artifact` named action authorised on the owner's
      # `{domain}.{doc_type}` scoped to the owner's `doc_id`; AND the
      # doctype must declare `publish_artifact` in its `actions` map. Two
      # separate gates, both required (defense in depth).
      def self.mint_permanent(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        owner_id : String,
      ) : SignedURL | Error
        # 1. Load the owner row — it points at a real document and is the
        #    target of the publish permission. Mistype → 404 (non-disclosing
        #    against probing).
        owner = ::Facet::Artifact::Store.find_owner_row(db, owner_id)
        return Error.new(404, "Owner row not found") unless owner

        # 2. Load the artifact (for the response shape — the signed URL's
        #    `artifacts` row id is what the verifier reads off the row).
        artifact = ::Facet::Artifact::Store.find_artifact(db, owner.artifact_id)
        return Error.new(404, "Artifact not found") unless artifact
        return Error.new(410, "Artifact deleted") if artifact.deleted_at

        # 3. Doctype gate — the doctype must declare `publish_artifact` in
        #    its `actions` map. This is the author intent gate; the
        #    permission gate is below. A doctype that hasn't declared the
        #    action has no publishable attachments (the intended default).
        definition = ::Facet::Doctype::DefinitionStore.fetch(
          db, "#{owner.domain}.#{owner.doc_type}",
        )
        return Error.new(403, "Forbidden") unless definition
        return Error.new(403, "Forbidden") unless definition.actions.has_key?(PUBLISH_ACTION_NAME)

        # 4. Permission gate — the role must grant `publish_artifact` on
        #    the leaf doctype scoped to `doc_id`. System bypass covers this
        #    via the existing WriteEnforcer short-circuit.
        unless ::Facet::RBAC::WriteEnforcer.authorize_action(
                 db, owner.domain, owner.doc_type, owner.doc_id,
                 PUBLISH_ACTION_NAME, auth_context,
               )
          return Error.new(403, "Forbidden")
        end

        # 5. Insert and sign. Permanent grants carry `expires_at = nil`.
        grant = insert_grant(
          db,
          artifact_id: artifact.id,
          owner_id: owner.id,
          kind: PERMANENT_KIND,
          expires_at: nil,
          created_by: auth_context.account_id,
        )

        sign(grant, nil)
      end

      # ── Revoke ──────────────────────────────────────────────────────────

      # Deletes a grant row. Hard delete — the row is gone and any URL
      # minted under it stops verifying immediately (epoch is irrelevant:
      # the row is gone, the verifier reads `nil` and rejects).
      #
      # Auth: system bypass, `publish_artifact` on the grant's owner's
      # provenance document, or the operator `revoke *.*` action (the
      # artifact admin surface). Minting is authorisation to publish;
      # revoking is the same privilege — `read` alone is insufficient.
      def self.revoke(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        grant_id : String,
      ) : Error?
        grant = find_grant(db, grant_id)
        return Error.new(404, "Grant not found") unless grant

        # System bypass — internal callers (CLI, reconcile) can revoke
        # any grant. Goes through the same `nil`-return path on success.
        unless auth_context.system?
          owner = ::Facet::Artifact::Store.find_owner_row(db, grant.owner_id)
          return Error.new(404, "Owner row not found") unless owner

          # Permission gate — publish_artifact on the owner's doc.
          authorized = ::Facet::RBAC::WriteEnforcer.authorize_action(
            db, owner.domain, owner.doc_type, owner.doc_id,
            PUBLISH_ACTION_NAME, auth_context,
          )

          # Operator gate — the `revoke *.*` admin action. Only consulted
          # when the publish privilege does not match: a grant that a
          # publisher may revoke stays publisher-scoped, and the operator
          # action reaches grants whose owner doctype grants them nothing.
          unless authorized
            result = auth_context.can?(REVOKE_ACTION, "*.*")
            return Error.new(403, "Forbidden") if result.is_a?(::Facet::RBAC::CanResult::Denied)
          end
        end

        db.exec("DELETE FROM artifact_grants WHERE id = $1", grant_id)
        nil
      end

      # Bumps an artifact's `epoch`. Invalidates every grant minted against
      # every owner row for the artifact, because the verifier reads `epoch`
      # off the row before performing any HMAC work — a bumped epoch yields
      # a different signature than what was issued, so the URL becomes
      # invalid immediately under either secret.
      #
      # The `facet artifacts:revoke` CLI calls this method. It revokes
      # every signed URL for one artifact.
      def self.bump_epoch(db : DB::Connection, artifact_id : String) : Nil
        db.exec(
          "UPDATE artifact_grants SET epoch = epoch + 1 WHERE artifact_id = $1",
          artifact_id,
        )
      end

      # ── Prune (cron) ────────────────────────────────────────────────────

      # The maximum number of rows per DELETE batch. Caps the `ANY($1)`
      # array size so the bind payload stays bounded.
      PRUNE_BATCH_SIZE = 1000

      # Deletes `ephemeral` grant rows that expired at least
      # `retention_days` ago. Permanent rows (`kind = 'permanent'`,
      # `expires_at` NULL) never match — the comparison filters them out.
      # A window of 0 or less deletes nothing — 0 means keep forever.
      #
      # Each batch is its own implicit transaction, so a failure does not
      # roll back earlier batches and a rerun resumes where the failed run
      # stopped. Idempotent — a deleted row does not match again. Returns
      # the number of rows removed.
      #
      # A deleted row is safe for the serve route: `verify` reads the row
      # before the expiry check and answers `unknown grant` — the same
      # hard failure an expired row already produced. No caller can tell
      # a pruned row from an expired one.
      def self.prune_expired(db : DB::Connection, retention_days : Int32) : Int32
        return 0 if retention_days <= 0
        total = 0
        loop do
          ids = select_prunable_ids(db, retention_days)
          break if ids.empty?

          db.exec("DELETE FROM artifact_grants WHERE id = ANY($1)", ids)
          total += ids.size
          break if ids.size < PRUNE_BATCH_SIZE
        end
        total
      end

      # Returns the ids of prunable rows: `ephemeral`, with an `expires_at`
      # at least `retention_days` in the past. `expires_at` and `now()` are
      # both tz-naive UTC, so the interval comparison is deterministic (see
      # the Time / Timezone contract).
      private def self.select_prunable_ids(db : DB::Connection, retention_days : Int32) : Array(String)
        db.query_all(
          <<-SQL,
            SELECT id FROM artifact_grants
            WHERE kind = 'ephemeral'
              AND expires_at <= now() - make_interval(days => $1)
            LIMIT #{PRUNE_BATCH_SIZE}
          SQL
          retention_days,
          as: String,
        )
      end

      # ── Verify (serve route) ────────────────────────────────────────────

      # Verifies a signed URL against the stored grant row. The grant must
      # exist, must not have expired, and the HMAC over the row's stored
      # `artifact_id` + `epoch` must match (first with the current secret,
      # then with the previous rotation key).
      #
      # `exp_param` and `sig_param` are the raw query-string values — the
      # caller passes them through verbatim so this method can validate the
      # signed shape rather than a decoded one.
      def self.verify(
        db : DB::Connection,
        grant_id : String,
        exp_param : String?,
        sig_param : String?,
      ) : VerifyResult
        return InvalidResult.new("missing signature") if sig_param.nil? || sig_param.empty?

        # 1. Load the grant row. Read epoch / artifact_id / expires_at off
        #    the row BEFORE any HMAC work — this is what makes `epoch` bumps
        #    invalidate grants signed under either secret.
        grant = find_grant(db, grant_id)
        return InvalidResult.new("unknown grant") unless grant

        # 2. Expiry — checked off the row's stored `expires_at`. Permanent
        #    grants have `nil`. Ephemeral grants reject when `now()` is past
        #    the row's expiry.
        if (exp_at = grant.expires_at) && exp_at < Time.utc
          return InvalidResult.new("expired")
        end

        # 3. Expected `exp` segment — the row's expiry (unix seconds, or
        #    the permanent sentinel). The verifier recomputes the signature
        #    using the row's value, NOT the URL's query param — this binds
        #    the signature to the row's identity.
        exp_segment = exp_segment_for(grant)

        # 4. Recompute the signature over the row's stored `artifact_id`
        #    and `epoch`. Constant-time compare. On mismatch, retry with
        #    the previous rotation key.
        if signature_matches?(grant_id, grant, exp_segment, sig_param, current_secret?)
          return valid_result(db, grant)
        end

        # Two-key rotation: try the previous secret.
        previous_secret = previous_secret?
        return InvalidResult.new unless previous_secret
        if signature_matches?(grant_id, grant, exp_segment, sig_param, previous_secret)
          return valid_result(db, grant)
        end

        InvalidResult.new
      end

      # ── Internal ────────────────────────────────────────────────────────

      # Loads an artifact and gates on tombstones: 404 when the row is
      # missing, 410 when soft-deleted. Shared by both ephemeral mint paths.
      private def self.load_live_artifact(db : DB::Connection, artifact_id : String) : Store::Artifact | Error
        artifact = ::Facet::Artifact::Store.find_artifact(db, artifact_id)
        return Error.new(404, "Artifact not found") unless artifact
        return Error.new(410, "Artifact deleted") if artifact.deleted_at
        artifact
      end

      # Computes the media-aware TTL for the artifact's MIME type, inserts
      # the ephemeral grant row, and signs the URL — the shared tail of both
      # ephemeral mint paths. `created_by` is the account id (user path) or
      # the `app:<app_id>` sentinel (app-origin path).
      private def self.insert_and_sign_ephemeral(
        db : DB::Connection,
        artifact_id : String,
        owner_id : String,
        created_by : String,
        mime_type : String,
      ) : SignedURL
        ttl_seconds = ephemeral_ttl_seconds(db, mime_type)
        expires_at = Time.utc + ttl_seconds.seconds

        grant = insert_grant(
          db,
          artifact_id: artifact_id,
          owner_id: owner_id,
          kind: EPHEMERAL_KIND,
          expires_at: expires_at,
          created_by: created_by,
        )

        sign(grant, expires_at)
      end

      # Returns true when `mime_type` is audio/* or video/* — the
      # longer-TTL case. (Anything else uses the short window.)
      private def self.media_ttl?(mime_type : String) : Bool
        mime_type.starts_with?("audio/") || mime_type.starts_with?("video/")
      end

      # Resolves the media-aware TTL at mint time from the runtime settings
      # (document → file → default), so an admin change applies to the next
      # grant without a restart. Falls back to the file value when the
      # settings read comes back empty or out of range — a grant row always
      # carries a sane expiry.
      private def self.ephemeral_ttl_seconds(db : DB::Connection, mime_type : String) : Int32
        media = media_ttl?(mime_type)
        path = media ? "artifact.grant_ttl_media_seconds" : "artifact.grant_ttl_seconds"
        fallback = media ? ::Facet::Config.instance.artifact.grant_ttl_media_seconds : ::Facet::Config.instance.artifact.grant_ttl_seconds
        n = SystemSettings.int_at(db, path)
        n.nil? || n < 1 || n > Int32::MAX ? fallback : n.to_i32
      end

      # Picks the first owner row for which the caller's `readable`
      # predicate holds. Used by both ephemeral mint paths to bind the
      # grant to a portable provenance.
      private def self.pick_owner(db : DB::Connection, artifact_id : String, &readable : Store::OwnerRow -> Bool) : Store::OwnerRow?
        owners = ::Facet::Artifact::Store.find_owner_rows(db, artifact_id)
        owners.each do |owner|
          next unless readable.call(owner)
          return owner
        end
        nil
      end

      # Picks the first readable owner row for an artifact. Used by
      # `mint_ephemeral` to bind the grant to a portable provenance. For
      # `mint_permanent`, the caller supplies the owner explicitly.
      private def self.pick_readable_owner(
        db : DB::Connection,
        auth_context : ::Facet::RBAC::AuthContext,
        artifact_id : String,
      ) : Store::OwnerRow?
        # Use the row-level access check to avoid double-loading owner
        # rows (the public `can_read?` re-fetches from the same id).
        pick_owner(db, artifact_id) do |owner|
          ::Facet::Artifact::Access.can_read_owner?(db, auth_context, owner)
        end
      end

      # Picks the first owner row the app grant ceiling covers (mirror of
      # `pick_readable_owner` for the anonymous app-origin path). Returns the
      # first `OwnerRow` whose provenance document is live and whose
      # `(domain, [doc_type])` is covered by some grant action that permits
      # `read`. Account-scoped standalone-upload owners never match (they
      # are bound to an account, not a document grant).
      private def self.pick_owner_for_app(
        db : DB::Connection,
        app_scope : ::Facet::RBAC::AppScope,
        artifact_id : String,
      ) : Store::OwnerRow?
        pick_owner(db, artifact_id) do |owner|
          ::Facet::Artifact::Access.owner_readable_for_app?(db, app_scope, owner)
        end
      end

      # Picks the first owner row of any kind — the operator mint binds to
      # it for provenance bookkeeping only; no ACL runs at serve time.
      private def self.pick_first_owner(db : DB::Connection, artifact_id : String) : Store::OwnerRow?
        ::Facet::Artifact::Store.find_owner_rows(db, artifact_id).first?
      end

      # Inserts an `artifact_grants` row. The grant id is minted by the
      # database (`ulid()` default) and surfaces in the signed URL.
      private def self.insert_grant(
        db : DB::Connection,
        artifact_id : String,
        owner_id : String,
        kind : String,
        expires_at : Time?,
        created_by : String,
      ) : Grant
        expires_str = expires_at.try(&.to_utc.to_s("%Y-%m-%d %H:%M:%S.%N"))

        # `query_one` (not `?`) — INSERT … RETURNING always yields a row
        # unless the insert itself failed, which is a DB error and the
        # correct blast radius. Avoids the `not_nil!` chain on the tuple.
        id_, aid, oid, kind_, exp_at, epoch, cby, cat = db.query_one(
          <<-SQL,
            INSERT INTO artifact_grants (artifact_id, owner_id, kind, expires_at, created_by)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING id, artifact_id, owner_id, kind, expires_at, epoch, created_by, created_at
          SQL
          artifact_id, owner_id, kind, expires_str, created_by,
          as: {String, String, String, String, Time?, Int32, String, Time},
        )

        Grant.new(
          id: id_,
          artifact_id: aid,
          owner_id: oid,
          kind: kind_,
          expires_at: exp_at,
          epoch: epoch,
          created_by: cby,
          created_at: cat,
        )
      end

      # Loads a grant row by id. Returns `nil` when the grant doesn't exist.
      def self.find_grant(db : DB::Connection, grant_id : String) : Grant?
        row = db.query_one?(
          <<-SQL,
            SELECT id, artifact_id, owner_id, kind, expires_at, epoch, created_by, created_at
            FROM artifact_grants
            WHERE id = $1
          SQL
          grant_id,
          as: {String, String, String, String, Time?, Int32, String, Time},
        )
        return nil unless row

        id_, aid, oid, kind, expires_at, epoch, created_by, created_at = row
        Grant.new(
          id: id_,
          artifact_id: aid,
          owner_id: oid,
          kind: kind,
          expires_at: expires_at,
          epoch: epoch,
          created_by: created_by,
          created_at: created_at,
        )
      end

      # The `exp` segment that goes into the HMAC for this grant. For
      # ephemeral grants: the unix seconds of the row's `expires_at`. For
      # permanent grants: the `PERMANENT_EXP_TOKEN` literal.
      private def self.exp_segment_for(grant : Grant) : String
        if exp = grant.expires_at
          exp.to_unix.to_s
        else
          PERMANENT_EXP_TOKEN
        end
      end

      # Computes the HMAC over the row's stored `grant_id|artifact_id|exp|epoch`.
      # The `secret` is supplied by the caller to support both current and
      # previous rotation keys without re-fetching the config.
      private def self.compute_hmac(
        grant_id : String,
        artifact_id : String,
        exp_segment : String,
        epoch : Int32,
        secret : String,
      ) : String
        payload = "#{grant_id}|#{artifact_id}|#{exp_segment}|#{epoch}"
        digest = ::OpenSSL::HMAC.digest(:sha256, secret, payload)
        # Base64url without padding — compact, URL-safe.
        Base64.urlsafe_encode(digest, padding: false)
      end

      # Returns true when `sig_param` matches the recomputed HMAC over
      # `(grant_id, grant.artifact_id, exp_segment, grant.epoch)` under
      # `secret`. Constant-time compare.
      private def self.signature_matches?(
        grant_id : String,
        grant : Grant,
        exp_segment : String,
        sig_param : String,
        secret : String,
      ) : Bool
        expected = compute_hmac(
          grant_id, grant.artifact_id, exp_segment, grant.epoch, secret,
        )
        Util::Crypto.constant_time_eq?(expected, sig_param)
      end

      # Loads the artifact for `grant` and produces a `Valid` result. If the
      # artifact is gone or tombstoned (torn write between delete and grant
      # revoke), surfaces as `Invalid` — the caller response shape treats
      # every `Invalid` as `403`, deliberately non-disclosing (the caller
      # must not learn whether the grant was invalid vs. the artifact gone).
      private def self.valid_result(
        db : DB::Connection,
        grant : Grant,
      ) : VerifyResult
        artifact = ::Facet::Artifact::Store.find_artifact(db, grant.artifact_id)
        return InvalidResult.new("artifact missing") if artifact.nil?
        return InvalidResult.new("artifact deleted") if artifact.deleted_at
        ValidResult.new(grant, artifact)
      end

      # The current HMAC secret. Always set — `Config` fails loud when
      # `artifact_grant_secret` is missing or empty.
      private def self.current_secret? : String
        ::Facet::Config.instance.artifact_grant_secret
      end

      # The previous rotation key. `nil` when rotation is not active.
      private def self.previous_secret? : String?
        ::Facet::Config.instance.artifact_grant_secret_previous
      end

      # Builds the signed URL for a freshly-minted grant. The grant id
      # becomes the path; `exp` and `sig` go in the query string.
      private def self.sign(
        grant : Grant,
        expires_at : Time?,
      ) : SignedURL
        exp_seg = exp_segment_for(grant)
        secret = current_secret?
        sig = compute_hmac(grant.id, grant.artifact_id, exp_seg, grant.epoch, secret)
        base = ::Facet::Config.instance.artifact_base_url
        if expires_at
          url = "#{base}/A/#{grant.id}?exp=#{exp_seg}&sig=#{sig}"
        else
          # Permanent grants omit exp from the URL. The signature still
          # signs `nil → PERMANENT_EXP_TOKEN` so the verifier can recompute.
          url = "#{base}/A/#{grant.id}?exp=#{PERMANENT_EXP_TOKEN}&sig=#{sig}"
        end

        SignedURL.new(
          grant_id: grant.id,
          artifact_id: grant.artifact_id,
          expires_at: expires_at,
          epoch: grant.epoch,
          url: url,
        )
      end
    end
  end
end

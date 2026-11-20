# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../config"
require "../database"
require "../doctype/definition_store"
require "../rbac/auth_context"
require "../mutation/provenance"
require "../agent_tools"
require "../artifact/grants"
require "../artifact/refs"
require "../artifact/store"
require "../artifact/upload_grants"
require "./errors"
require "./discover"

module Facet
  module AgentTools
    # Artifact tool group: file upload and download capabilities for an
    # external agent.
    #
    # - `request_artifact_upload` — mints a one-time signed upload URL.
    #   No bytes ride the tool arguments: the agent's HTTP client POSTs
    #   the multipart body straight to the artifact origin, so the MCP
    #   envelope (`mcp.max_response_bytes`) never bounds a file. The
    #   upload lands through the standard `Artifact::Uploader.upload`
    #   machinery and returns the artifact id the agent then puts into a
    #   document (a `file` field value, or a `urn:facet:artifact:<id>`
    #   link in longtext — the re-attach flow appends the owner row).
    # - `get_artifact` — mints a short-lived signed download URL for one
    #   artifact the caller can read (provenance-based, same gate as the
    #   REST metadata route). The agent fetches the bytes over plain HTTP.
    # - `list_artifact_refs` — the "where is this artifact used" listing
    #   for one artifact the caller can read: the live documents whose
    #   `file` fields hold the id or whose longtext embeds a
    #   `urn:facet:artifact:<id>` link (the `artifact_references` rows,
    #   via `Artifact::Refs`). Referrers are filtered per record — each
    #   returned row passed its own doctype's list scope.
    #
    # Visibility: `request_artifact_upload` requires at least one
    # create/update/delete permission line (the `:write` requirement — an
    # artifact is only useful to a caller that can write somewhere);
    # `get_artifact` and `list_artifact_refs` require a `read` line (the
    # `:read` requirement).
    module Artifacts
      def self.entries : Array(Registry::Entry)
        [
          Registry::Entry.new(
            name: "request_artifact_upload",
            description: "Get a one-time signed upload URL for a file artifact. The URL is single-use and expires in about 5 minutes — upload immediately after minting. POST multipart/form-data to upload_url with exactly one part named 'file' carrying the raw bytes (send the file as the part body; do not base64-encode it, do not send JSON). Send the request WITHOUT an Authorization header — the URL signature is the credential, and a bearer token (for example an MCP token) is rejected by the REST auth gate. A successful upload answers 201 {id, filename, mime_type, size, sha256}; 403 with a 'reason' body means the URL expired or was already used — call this tool again for a fresh URL. Then link the returned id into a document with create_document or update_document: as the value of a 'file' field, or as a '[filename](urn:facet:artifact:<id>)' link inside a longtext field. After saving, verify the reference landed with list_artifact_refs — an unlinked upload is swept by prune after the retention window. 'size_bytes' (optional) is checked against the server cap up front so an oversized file fails before any bytes move.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "filename":   {"type": "string", "description": "File name to store (used for the metadata record and extension fallbacks)"},
                "size_bytes": {"type": "integer", "minimum": 0, "description": "Optional file size — rejected up front when it exceeds the server's max_upload_bytes"}
              },
              "required": ["filename"]
            })),
            requires: :write,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { request_artifact_upload(ctx, args) },
          ),
          Registry::Entry.new(
            name: "get_artifact",
            description: "Mint a short-lived signed download URL for one artifact. The artifact id comes from a 'file' field value or a urn:facet:artifact:<id> link inside a document. The caller must be able to read the artifact (provenance-based) — a denied or unknown id raises. The URL expires (about 1 hour for documents and images, 6 hours for audio/video); call the tool again to mint a fresh one. Returns {data: {id, filename, mime_type, size, download_url}, meta: {expires_at}} — fetch download_url with a plain HTTP GET.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "artifact_id": {"type": "string", "description": "The artifact id (the value of a file field, or the id inside a urn:facet:artifact: link)"}
              },
              "required": ["artifact_id"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { get_artifact(ctx, args) },
          ),
          Registry::Entry.new(
            name: "list_artifact_refs",
            description: "List the live documents that currently reference one artifact — both 'file' field placements and inline urn:facet:artifact:<id> links in longtext. You must be able to read the artifact (provenance-based): an unknown, deleted, or denied id raises NotFound, with no distinction between the three. Referrers are filtered per record — only documents you can read are returned, unreadable doctypes are skipped silently (the same non-disclosure as get_backrefs), so an empty list means 'no references you can see'. Use it to verify a link landed after an upload (an unlinked upload is swept by prune) and to survey usage before replacing or deleting an artifact. Returns {data: [{id, domain, doc_type, display_name, field, last_reference_at}], meta: {artifact, total, capped}}; total counts the returned rows only.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "artifact_id": {"type": "string", "description": "The artifact id (the value of a file field, or the id inside a urn:facet:artifact: link)"}
              },
              "required": ["artifact_id"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { list_artifact_refs(ctx, args) },
          ),
        ] of Registry::Entry
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.request_artifact_upload(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        filename = Discover.string_arg(args, "filename")
        max = ::Facet::Config.instance.artifact.max_upload_bytes

        if size = optional_int_arg(args, "size_bytes")
          if size > max
            raise InvalidParams.new(
              "'size_bytes' (#{size}) exceeds the server cap of #{max} bytes — the upload would be rejected with 413",
              data: AgentTools.invalid_params_data("size_bytes"),
            )
          end
        end

        minted = ::Facet::Artifact::UploadGrants.mint(ctx.auth_context)
        JSON::Any.new({
          "data" => JSON::Any.new({
            "upload_url" => JSON::Any.new(minted.url),
            "method"     => JSON::Any.new("POST"),
            "field"      => JSON::Any.new("file"),
            "filename"   => JSON::Any.new(filename),
          } of String => JSON::Any),
          "meta" => JSON::Any.new({
            "expires_at" => JSON::Any.new(minted.expires_at.to_rfc3339),
            "max_bytes"  => JSON::Any.new(max),
          } of String => JSON::Any),
        })
      end

      private def self.get_artifact(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        artifact_id = Discover.string_arg(args, "artifact_id")

        # Load first so the unknown / tombstoned paths surface as NotFound —
        # the same distinction the REST metadata route makes — while the
        # provenance denial stays RbacDenied.
        artifact = ::Facet::Artifact::Store.find_artifact(ctx.db, artifact_id)
        raise NotFound.new("Artifact not found") unless artifact
        raise NotFound.new("Artifact not found (deleted)") if artifact.deleted_at

        case result = ::Facet::Artifact::Grants.mint_ephemeral(ctx.db, ctx.auth_context, artifact_id)
        in ::Facet::Artifact::Grants::SignedURL
          artifact = ::Facet::Artifact::Store.find_artifact(ctx.db, artifact_id)
          exp = result.expires_at
          expires_at_json = exp ? JSON::Any.new(exp.to_rfc3339) : JSON::Any.new(nil)
          JSON::Any.new({
            "data" => JSON::Any.new({
              "id"           => JSON::Any.new(artifact_id),
              "filename"     => JSON::Any.new(artifact.try(&.filename) || ""),
              "mime_type"    => JSON::Any.new(artifact.try(&.mime_type) || ""),
              "size"         => JSON::Any.new(artifact.try(&.size) || 0_i64),
              "download_url" => JSON::Any.new(result.url),
            } of String => JSON::Any),
            "meta" => JSON::Any.new({
              "expires_at" => expires_at_json,
            } of String => JSON::Any),
          })
        in ::Facet::Artifact::Grants::Error
          # Only the provenance denial can reach here now — the artifact
          # was already loaded live above.
          raise AgentTools.service_error(
            ::Facet::ServiceError.new(result.status, result.message),
            "Artifact",
          )
        end
      end

      # Lists the live documents that reference one artifact. Delegates to
      # `Artifact::Refs`, which owns the contract: the artifact gate runs
      # first (unknown, deleted, ownerless, or denied → one non-disclosing
      # NotFound — deliberately stricter than `get_artifact`, whose denial
      # surfaces as RbacDenied); the referrer side filters each
      # `(domain, doc_type)` group by its list scope clauses, so a referrer
      # row can never leak past the caller's list visibility. `capped`
      # reports honestly when the result set reaches the
      # `mcp.max_result_rows` cap; `total` counts returned rows only — a
      # count over all references would leak unreadable cardinality.
      private def self.list_artifact_refs(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        artifact_id = Discover.string_arg(args, "artifact_id")

        result = ::Facet::Artifact::Refs.call(
          ctx.db, ctx.auth_context, artifact_id,
          limit: Facet::Config.instance.mcp.max_result_rows,
        )
        case result
        in ::Facet::Artifact::Refs::Result
          JSON::Any.new({
            "data" => JSON::Any.new(result.items.map { |item| ref_json(item) }),
            "meta" => JSON::Any.new({
              "artifact" => JSON::Any.new(artifact_id),
              "total"    => JSON::Any.new(result.items.size.to_i64),
              "capped"   => JSON::Any.new(result.capped),
            } of String => JSON::Any),
          })
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "Artifact #{artifact_id}")
        end
      end

      # Maps one service item to the reference-row shape the tool contract
      # carries (`display_name` null when the doctype declares no template;
      # `last_reference_at` is prune metadata, not document content).
      private def self.ref_json(item : ::Facet::Artifact::Refs::Item) : JSON::Any
        JSON::Any.new({
          "id"                => JSON::Any.new(item.id),
          "domain"            => JSON::Any.new(item.domain),
          "doc_type"          => JSON::Any.new(item.doc_type),
          "display_name"      => item.display_name.nil? ? JSON::Any.new(nil) : JSON::Any.new(item.display_name),
          "field"             => JSON::Any.new(item.field),
          "last_reference_at" => JSON::Any.new(item.last_reference_at.to_rfc3339),
        } of String => JSON::Any)
      end

      # Extracts an optional integer argument. Absent → nil; present but
      # not an integer → `InvalidParams` naming the argument.
      private def self.optional_int_arg(args : JSON::Any, key : String) : Int64?
        value = args.as_h?.try(&.[key]?)
        return nil if value.nil? || value.raw.nil?
        value.as_i64? || raise InvalidParams.new(
          "Invalid argument '#{key}' (expected an integer)",
          data: AgentTools.invalid_params_data(key),
        )
      end
    end
  end
end

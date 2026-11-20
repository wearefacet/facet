# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../event"
require "../http/helpers"
require "../http/nested_path_resolver"
require "../document/sidecar_handler"
require "../rbac"
require "../rbac/read_enforcer"
require "../document/create"
require "../document/read"
require "../document/update"
require "../document/delete"
require "../document/action"
require "../document/list"
require "../mutation/client"

module Facet
  module HTTP
    # REST catch-all routes for nested document paths.
    #
    # These handle paths like `/Api/:domain/:doctype/:id/contacts` (list children)
    # and `/Api/:domain/:doctype/:id/contacts/:child_id` (read/write a child).
    #
    # Registered by `HTTP::Server.routes`.
    module RestRoutes
      # First path segments that host no document doctypes — virtual or
      # operator namespaces. `DomainGate::RESERVED_SEGMENTS` owns the
      # full reservation list; `iam`, `search` and `assistant` are left
      # out here because real documents live (or may live) under them,
      # and their nested children stay served by this catch-all.
      VIRTUAL_NAMESPACES = %w[Audit Indexes Artifacts SystemSettings openapi.json]

      def self.register : Nil
        {% for m in %w[get post patch delete] %}
          {{m.id}} "/Api/:domain/:doctype/:id/*rest" do |env|
            handle_rest(env, env.params.url["domain"], env.params.url["doctype"], env.params.url["id"], env.params.url["rest"], "{{m.id}}")
          end
        {% end %}
      end

      # ── Rest route dispatch ─────────────────────────────────────────────

      # Entry point — parses the rest path and delegates to method-specific handlers.
      private def self.handle_rest(env, domain, root_doctype, root_id, rest_raw, method)
        segments = rest_raw.split('/').reject(&.empty?)
        env.response.content_type = "application/json"

        # A deep path under a virtual namespace matched no dedicated route.
        # The segment must not read as a document domain — the machinery
        # answered "Unknown doctype: Audit.<id>" for /Api/Audit/... URLs.
        # The 404 body mirrors the gate's answer for reserved segments.
        if VIRTUAL_NAMESPACES.includes?(domain)
          return Helpers.write_json_error(env, 404, "Not found")
        end

        if segments.empty?
          return Helpers.write_json_error(env, 400, "Nested path is empty")
        end

        # A client may address the root document by its fully qualified
        # reference token ("hr.Employee.<id>") — e.g. a capsule click opens
        # /Api/{domain}/{doctype}/{token}/history. Resolve it to the row's
        # stored id before any dispatch (read, action, rollback, children).
        root_id = Helpers.canonical_doc_id(domain, root_doctype, root_id)

        case method
        when "get"   then rest_get(env, domain, root_doctype, root_id, segments)
        when "post"  then rest_post(env, domain, root_doctype, root_id, segments)
        when "patch" then rest_patch(env, domain, root_doctype, root_id, segments)
        else              rest_delete(env, domain, root_doctype, root_id, segments)
        end
      end

      # GET: sidecar dispatch first (1 segment → list, 2 segments → read a
      # sidecar document), then odd segments → list children, even segments →
      # read a child document.
      private def self.rest_get(env, domain, root_doctype, root_id, segments)
        # Per-document sidecar read: dispatched BEFORE the child parent
        # resolution — a 2-segment sidecar path is not a child walk, and
        # `resolve_immediate_parent` would 404 it as an unknown child. A
        # segment cannot be both a sidecar and a child (publish-time
        # validation), so there is no ambiguity. Deeper paths fall through —
        # a sidecar never hosts anything.
        if segments.size == 2
          rendered = render_sidecar_read(env, domain, root_doctype, root_id, segments[0], segments[1])
          return rendered unless rendered.nil?
        end

        parent_defn, immediate_parent_id, parent_err =
          resolve_immediate_parent(domain, root_doctype, root_id, segments)
        if parent_err
          Helpers.write_json_error(env, parent_err[:status], parent_err[:message])
          return
        end

        auth_ctx = Helpers.auth_context(env)

        # RBAC parent gate. Runs before ANY response — including an ETag 304 —
        # so a caller without access always gets an authorization answer,
        # never a cache short-circuit. A caller with no read grant on the
        # parent doctype at all answers 403 — the class-level denial the
        # write side gives. A grant holder that cannot see this parent
        # gets the non-disclosing 404 below: for them a missing and an
        # out-of-scope parent are indistinguishable. For a single-segment
        # path the immediate parent IS the root document, so this gate
        # also covers the sidecar list branch below
        # (`Document::SidecarHandler.list` re-checks its gates
        # defensively).
        if Facet::RBAC::ReadEnforcer.read_denied?(domain, parent_defn.as(Facet::Doctype::DoctypeDefinition).doctype, auth_ctx)
          Helpers.write_json_error(env, 403, "Forbidden")
          return
        end
        parent_authorized = Database.with_db(:read_only) do |db|
          Facet::RBAC::ReadEnforcer.parent_authorized?(
            db, domain, parent_defn.as(Facet::Doctype::DoctypeDefinition).doctype,
            immediate_parent_id.as(String), auth_ctx
          )
        end
        unless parent_authorized
          Helpers.write_json_error(env, 404, "Not found")
          return
        end

        # Sidecar collection: the segment must be a key in the host's
        # `sidecars` map. Checked before the child resolution — a segment
        # cannot be both a sidecar and a child (publish-time validation), so
        # there is no ambiguity. Only the single-segment form is a sidecar
        # collection; the 2-segment form was handled above as a per-document
        # sidecar read; deeper paths fall through to the child resolver.
        if segments.size == 1
          rendered = render_sidecar_list(env, domain, root_doctype, root_id, segments[0], auth_ctx)
          return rendered unless rendered.nil?
        end

        if segments.size.odd?
          render_child_list(env, auth_ctx, domain, root_doctype, root_id, segments, immediate_parent_id.as(String))
        else
          render_child_read(env, auth_ctx, domain, root_doctype, root_id, segments)
        end
      end

      # Renders the child collection for the odd rest segments at any depth.
      # `parent_id` is the resolved immediate parent's document id — the ETag
      # version and the list query are both scoped to it.
      private def self.render_child_list(
        env,
        auth_ctx : Facet::RBAC::AuthContext,
        domain : String,
        root_doctype : String,
        root_id : String,
        segments : Array(String),
        parent_id : String,
      )
        _, doctype, _, err = resolve_child_target(domain, root_doctype, root_id, segments)
        if err
          Helpers.write_json_error(env, err[:status], err[:message])
          return
        end
        doctype = doctype.as(String)

        # The child doctype's own definition must resolve before the strict
        # parameter parse (B-366): the list-mode resolver checks the
        # relationship on the parent, not the child's definition row, and
        # an unknown child doctype must answer the list service's 404 —
        # never the grammar's 422.
        child_defn = Database.with_db(:read_only) { |db| Helpers.fetch_doctype_defn(db, "#{domain}.#{doctype}") }
        if child_defn.nil?
          Helpers.write_json_error(env, 404, "Unknown doctype: #{domain}.#{doctype}")
          return
        end

        # `aggregate`, `field`, and `filters` mirror the top-level list
        # route so a client can count, run a field aggregate (`sum` / `avg`
        # / `min` / `max`), or filter the children of a parent without
        # fetching them. Filters ride the same grammar and the same
        # validation as the flat route — a malformed filter answers 422,
        # never a silent unfiltered result (B-20/B-41). Unknown parameters
        # answer 422 the same way (the B-169 remainder). Other known list
        # params (page/items/sort/deleted) are not forwarded on child
        # lists, and the fingerprint below carries only the forwarded
        # values so an ignored parameter cannot break cache hits.
        child_req = HTTP::ListRequest.from_query(env.params.query, strict: true)
        if child_req.is_a?(Facet::ServiceError)
          Helpers.write_json_error(env, child_req.status, child_req.message)
          return
        end
        agg_val = child_req.aggregate
        field_val = child_req.field

        # ETag short-circuit — after the RBAC parent gate, before the items
        # query. The version is scoped to THIS parent's children
        # (`meta->>'parent_id'`), so two parents of the same doctype never
        # share a validator. The caller-supplied parameters are `aggregate`
        # and `field`; the fingerprint is built from a minimal
        # `ListRequest` carrying just those values, so parameters the route
        # ignores (e.g. a stray `?page=2`) cannot break cache hits, and two
        # aggregates over different fields never alias.
        version = Database.with_db(:read_only) do |db|
          Facet::Document::List.child_collection_version(db, domain, doctype.as(String), parent_id)
        end
        version_tag = version.try(&.to_rfc3339(fraction_digits: 6)) || "empty"
        child_list_req = HTTP::ListRequest.new(aggregate: agg_val, field: field_val, filters: child_req.filters)
        collection_tag = "#{Helpers.role_fingerprint(auth_ctx)}:#{Helpers.list_request_fingerprint(child_list_req)}:#{version_tag}"
        if Helpers.not_modified?(env, collection_tag)
          Helpers.write_not_modified(env, collection_tag)
          return
        end

        list_result = begin
          Database.with_db(:read_only) { |db| Facet::Document::List.call(db, domain, doctype.as(String), page: 1, items_per_page: 1000, auth_context: auth_ctx, parent_id: parent_id, filters: child_req.filters, aggregate: agg_val, field: field_val, authorize_path: composition_path(domain, root_doctype, root_id, segments), authorize_root_id: root_id) }
        rescue ex : PQ::PQError
          # Same contract as the top-level list route: aggregate requests
          # run uncapped, so a statement_timeout cancellation maps to 503.
          raise ex unless agg_val && Helpers.statement_timeout?(ex)
          Helpers.write_json_error(env, 503, "The request exceeded the server's statement timeout — narrow the filters and retry")
          return
        end
        case list_result
        in Facet::Document::List::Result
          write_list_result(env, list_result, collection_tag)
        in Facet::Document::List::AggregateResult
          # Aggregate payload over the parent's children — same contract as
          # the top-level list route (`more` is always false; `count` is the
          # contributing-row count from the same statement).
          env.response.status_code = 200
          env.response.content_type = "application/json"
          Helpers.set_etag_header(env, collection_tag)
          {data: {value: list_result.value}, meta: {count: list_result.count, more: false}}.to_json
        in Facet::ServiceError
          Helpers.write_json_error(env, list_result.status, list_result.message)
        end
      end

      # Renders a single child document read for the even rest segments at
      # any depth. The single-document ETag (304 short-circuit included) is
      # emitted by the `Document::Read::Result` branch of `Helpers.write_result`.
      private def self.render_child_read(
        env,
        auth_ctx : Facet::RBAC::AuthContext,
        domain : String,
        root_doctype : String,
        root_id : String,
        segments : Array(String),
      )
        t_domain, t_doctype, t_id, err = resolve_child_target(domain, root_doctype, root_id, segments)
        if err
          Helpers.write_json_error(env, err[:status], err[:message])
          return
        end

        expected_parent_id = resolve_expected_parent_id(domain, root_doctype, root_id, segments)
        if expected_parent_id && !child_belongs_to_parent?(t_domain.as(String), t_doctype.as(String), t_id.as(String), expected_parent_id)
          Helpers.write_json_error(env, 404, "Not found")
          return
        end

        result = Database.with_db(:read_only) { |db| Facet::Document::Read.call(db, t_domain.as(String), t_doctype.as(String), t_id.as(String), auth_ctx, authorize_path: composition_path(domain, root_doctype, root_id, segments), authorize_root_id: root_id) }
        Helpers.write_result(env, result)
      end

      # Renders a sidecar list response when `segment` matches a key in the
      # host's `sidecars` map. Returns the JSON response string on success or
      # error, or `nil` when the segment is not a sidecar (so the caller falls
      # through to the child resolver). The host must be a single-segment
      # collection path — deeper paths are not sidecar collections.
      #
      # Authorization gates run before any response — including an ETag 304 —
      # so a caller without access gets the non-disclosing 404, never a cache
      # short-circuit. `Document::SidecarHandler.list` re-runs the same gates before its
      # query.
      private def self.render_sidecar_list(
        env,
        domain : String,
        root_doctype : String,
        root_id : String,
        segment : String,
        auth_ctx : Facet::RBAC::AuthContext,
      ) : String?
        host_defn = Database.with_db(:read_only) { |db| Helpers.fetch_doctype_defn(db, "#{domain}.#{root_doctype}") }
        return nil unless host_defn
        sidecar_ref = host_defn.sidecars[segment]?
        return nil unless sidecar_ref

        sidecar_domain, sidecar_doctype = Document::SidecarHandler.split_qualified(sidecar_ref.doctype)
        sidecar_authorized = Database.with_db(:read_only) do |db|
          Facet::RBAC::ReadEnforcer.sidecar_authorized?(db, domain, root_doctype, sidecar_domain, sidecar_doctype, auth_ctx)
        end
        unless sidecar_authorized
          Helpers.write_json_error(env, 404, "Not found")
          return ""
        end

        # ETag short-circuit — after the gates, before the items query. Every
        # parameter of a sidecar list is fixed by the path (the `target`
        # filter is the host URN), so the digest slot carries the constant
        # `sidecar` marker and the version is scoped to the host's rows.
        # Tombstones of the sidecar doctype enter the version WITHOUT the
        # target filter — delete clears `content`, so a tombstoned sidecar can
        # no longer be matched to its host (see
        # `Document::List.sidecar_collection_version`).
        version = Database.with_db(:read_only) do |db|
          Facet::Document::List.sidecar_collection_version(db, sidecar_domain, sidecar_doctype, sidecar_ref.column, "#{domain}.#{root_doctype}.#{root_id}")
        end
        version_tag = version.try(&.to_rfc3339(fraction_digits: 6)) || "empty"
        collection_tag = "#{Helpers.role_fingerprint(auth_ctx)}:sidecar:#{version_tag}"
        if Helpers.not_modified?(env, collection_tag)
          Helpers.write_not_modified(env, collection_tag)
          return ""
        end

        sidecar_result = Database.with_db(:read_only) do |db|
          Document::SidecarHandler.list(db, domain, root_doctype, root_id, segment, auth_ctx)
        end
        case sidecar_result
        in Facet::Document::List::Result
          write_list_result(env, sidecar_result, collection_tag)
        in Facet::ServiceError
          Helpers.error_response(env, sidecar_result.status, sidecar_result.message)
        end
      end

      # Renders a single sidecar document read when `segment` matches a key
      # in the host's `sidecars` map and the path is exactly two segments.
      # Returns the JSON response string on success or error, or `nil` when
      # the segment is not a sidecar (so the caller falls through to the
      # child resolver).
      #
      # Both authorization gates (host read + nested sidecar grant) run
      # inside `Document::SidecarHandler.read` before any response — there is no ETag
      # short-circuit on this path before the handler, so a caller without
      # access always gets the non-disclosing 404, never a cache
      # short-circuit. The single-document ETag (304 short-circuit included)
      # is emitted by the `Document::Read::Result` branch of
      # `Helpers.write_result`, after the gates passed.
      private def self.render_sidecar_read(
        env,
        domain : String,
        root_doctype : String,
        root_id : String,
        segment : String,
        sidecar_id : String,
      ) : String?
        _sidecar_domain, sidecar_doctype = resolve_sidecar_doctype(domain, root_doctype, segment)
        return nil unless sidecar_doctype

        result = Database.with_db(:read_only) do |db|
          Document::SidecarHandler.read(db, domain, root_doctype, root_id, segment, sidecar_id, Helpers.auth_context(env))
        end
        Helpers.write_result(env, result)
      end

      # PATCH/DELETE dispatch for a per-document sidecar write. Returns the
      # response body string when the request was handled (the body was
      # written to the response — Kemal routes echo this return value), or
      # `nil` when the segment is not a sidecar (caller falls through to the
      # child resolver).
      private def self.render_sidecar_write(
        env,
        domain : String,
        root_doctype : String,
        root_id : String,
        segments : Array(String),
        method : String,
        body : String,
      ) : String?
        return nil unless segments.size == 2

        sidecar_domain, sidecar_doctype = resolve_sidecar_doctype(domain, root_doctype, segments[0])
        return nil unless sidecar_doctype

        auth_ctx = Helpers.auth_context(env)
        result = Database.with_transaction do |db|
          sidecar_id = segments[1]
          case method
          when "patch"
            next Facet::ServiceError.new(404, "Not found") unless Helpers.lock_with_chain(db, sidecar_domain.as(String), sidecar_doctype.as(String), sidecar_id)
            Document::SidecarHandler.update(db, domain, root_doctype, root_id, segments[0], sidecar_id, body, auth_ctx)
          else
            next Facet::ServiceError.new(404, "Not found") unless Helpers.lock_with_chain(db, sidecar_domain.as(String), sidecar_doctype.as(String), sidecar_id)
            Document::SidecarHandler.delete(db, domain, root_doctype, root_id, segments[0], sidecar_id, auth_ctx)
          end
        end
        Event::Publisher.flush
        Helpers.write_result(env, result)
      end

      # Resolves the qualified sidecar doctype for a host segment through
      # the shared `Document::SidecarHandler.resolve_sidecar_ref` path. Returns
      # `{sidecar_domain, sidecar_doctype}` when the segment is a key in the
      # host's `sidecars` map, or `{nil, nil}` when it is not (caller falls
      # through) — also when the host doctype itself is unknown, or the
      # segment miss is surfaced as an error by the resolver.
      private def self.resolve_sidecar_doctype(domain : String, root_doctype : String, segment : String) : {String?, String?}
        qualified, err = Database.with_db { |db| Document::SidecarHandler.resolve_sidecar_ref(db, domain, root_doctype, segment) }
        return {nil, nil} if err || qualified.nil?

        Document::SidecarHandler.split_qualified(qualified)
      end

      # POST: single segment → action or child create; multi → nested child create.
      private def self.rest_post(env, domain, root_doctype, root_id, segments)
        return unless Helpers.require_csrf(env)

        body = Helpers.parse_body(env)
        if body.nil? || body.empty?
          Helpers.write_json_error(env, 422, "Request body is required")
          return
        end
        return if reject_unsupported_body(env, body)

        if segments.size == 1
          rest_post_root_child_or_action(env, domain, root_doctype, root_id, segments[0], body)
        else
          rest_post_deep_child(env, domain, root_doctype, root_id, segments, body)
        end
      end

      # ── Request media-type gate (B-113) ─────────────────────────────

      # The documented file intake for a multipart body is the standalone
      # artifact upload; a sidecar record is then created with a JSON
      # sidecar create. A multipart body on a nested document route is a
      # caller error, not a server fault.
      MULTIPART_REFUSAL = "multipart/form-data is not accepted on nested document routes — " \
                          "upload files through POST /Api/core/artifacts and send this route a JSON body " \
                          "(a sidecar record is created with a JSON sidecar create)"

      # Media-type gate for the nested POST/PATCH entry points, before any
      # body parse. A `multipart/form-data` body and any other declared
      # non-JSON media type answer `415`; a malformed body under a JSON
      # media type answers `400` here, at the earliest parse point — never
      # the 5xx an unguarded parse raised. A body with no Content-Type at
      # all keeps the flat document routes' tolerance: the body itself must
      # parse, and a wrong declared type is the caller error 415 answers.
      # Returns true when the error was written.
      private def self.reject_unsupported_body(env, body : String) : Bool
        header = env.request.headers["Content-Type"]?
        if header && header.downcase.starts_with?("multipart/form-data")
          Helpers.write_json_error(env, 415, MULTIPART_REFUSAL)
          return true
        end
        if header && !Helpers.json_content_type?(header)
          Helpers.write_json_error(env, 415, "Unsupported media type — nested document routes accept application/json")
          return true
        end
        begin
          JSON.parse(body)
        rescue ex : JSON::ParseException
          Helpers.write_json_error(env, 400, "Invalid JSON body: #{ex.message}")
          return true
        end
        false
      end

      # POST at a single depth: either an action invocation or a child create.
      private def self.rest_post_root_child_or_action(env, domain, root_doctype, root_id, rel_or_action, body)
        is_action = false
        result = Database.with_transaction do |db|
          defn = Helpers.fetch_doctype_defn(db, "#{domain}.#{root_doctype}")
          if defn
            # Sidecar create takes precedence over actions and children —
            # a segment cannot be both a sidecar and an action/child
            # (publish-time validation), so there is no ambiguity.
            if defn.sidecars.has_key?(rel_or_action)
              next Document::SidecarHandler.create(db, domain, root_doctype, root_id, rel_or_action, JSON.parse(body), Helpers.auth_context(env))
            end
            if defn.actions.has_key?(rel_or_action)
              is_action = true
              next Facet::ServiceError.new(404, "Not found") unless Helpers.lock_projection_for_update(db, domain, root_doctype, root_id)
              Facet::Document::Action.call(db, domain, root_doctype, root_id, rel_or_action, body, Helpers.auth_context(env))
            else
              child = defn.children[rel_or_action]?
              next unknown_child_error(rel_or_action, defn, include_sidecars: true, include_actions: true) if child.nil?
              # B-276: the child will link to this row, so the row must
              # exist and be live. The lock answer is the non-disclosing
              # 404 — a parent id that does not exist, or a real id of
              # another doctype, answers here and never stamps
              # meta.parent_id.
              next Facet::ServiceError.new(404, "Not found") unless Helpers.lock_live_projection_for_update(db, domain, root_doctype, root_id)
              parent_meta = {"parent_id" => JSON::Any.new(root_id)}
              # Nested child create authorizes on the composition path — a
              # grant/permission on the parent (or the full nested path)
              # covers it; the bare child path serves the flat route only.
              Facet::Document::Create.call(db, domain, child.doctype, body, Helpers.auth_context(env), meta_overrides: parent_meta, authorize_path: [root_doctype, child.doctype])
            end
          else
            Facet::ServiceError.new(404, "Unknown doctype: #{domain}.#{root_doctype}")
          end
        end
        Event::Publisher.flush
        Helpers.write_result(env, result, is_action ? 200 : 201)
      end

      # POST at a deeper level: create a child of a resolved target.
      private def self.rest_post_deep_child(env, domain, root_doctype, root_id, segments, body)
        if segments[0]? == "actions"
          # POST /Api/:domain/:doctype/:id/actions/:action lands here. Named
          # actions run at the single-segment route; name that route instead
          # of a 400 about child documents.
          action_name = segments[1]?
          route = action_name ? "/Api/#{domain}/#{root_doctype}/#{root_id}/#{action_name}" : "/Api/#{domain}/#{root_doctype}/#{root_id}/<action>"
          Helpers.write_json_error(
            env, 400,
            "Named actions run at 'POST #{route}' — the action name is one path segment; drop the 'actions/' prefix"
          )
          return
        end
        if segments.size.even?
          collection_path = "/Api/#{domain}/#{root_doctype}/#{root_id}/#{segments[0...-1].join('/')}"
          Helpers.write_json_error(
            env, 400,
            "POST targets a specific child document ('#{segments.last}'); to create a new child, POST to '#{collection_path}'"
          )
          return
        end

        t_domain, t_doctype, t_id, err = resolve_child_target(domain, root_doctype, root_id, segments[0...-1])
        if err
          Helpers.write_json_error(env, err[:status], err[:message])
          return
        end

        rel = segments.last
        result = Database.with_transaction do |db|
          defn = Helpers.fetch_doctype_defn(db, "#{t_domain}.#{t_doctype}")
          next Facet::ServiceError.new(404, "Unknown doctype: #{t_domain}.#{t_doctype}") unless defn
          child_rel = defn.children[rel]?
          next unknown_child_error(rel, defn) if child_rel.nil?
          # B-276: every parent hop in the URL must be a live row of its
          # resolved doctype — the same verdict the single-depth branch
          # runs on the root row.
          if err = verify_parent_hops(db, domain, root_doctype, root_id, segments)
            next err
          end
          parent_meta = {"parent_id" => JSON::Any.new(t_id.as(String))}
          # Composition-path authorization — see the single-depth branch.
          Facet::Document::Create.call(db, t_domain.as(String), child_rel.doctype, body, Helpers.auth_context(env), meta_overrides: parent_meta, authorize_path: composition_path(domain, root_doctype, root_id, segments))
        end
        Event::Publisher.flush
        Helpers.write_result(env, result, 201)
      end

      # Verifies every parent hop of a deep create (B-276): the root row and
      # each (relationship, id) pair before the last segment must be a live
      # row of the doctype the URL resolves it to. The walk mirrors
      # `NestedPathResolver`, but runs on the caller's transaction so each
      # verified row is also locked to commit — a concurrent parent delete
      # cannot land between the check and the child insert. A missing id,
      # or a real id of another doctype, answers the non-disclosing 404.
      # Returns the `Facet::ServiceError` to fail with, or `nil` when every
      # hop verified. Expects create-shaped segments: odd count, the last
      # segment is the relationship to create under.
      private def self.verify_parent_hops(db, domain, root_doctype, root_id, segments) : Facet::ServiceError?
        return Facet::ServiceError.new(404, "Not found") unless Helpers.lock_live_projection_for_update(db, domain, root_doctype, root_id)

        current_doctype = root_doctype
        idx = 0
        while idx < segments.size - 1
          hop_defn = Helpers.fetch_doctype_defn(db, "#{domain}.#{current_doctype}")
          return Facet::ServiceError.new(404, "Unknown doctype: #{domain}.#{current_doctype}") if hop_defn.nil?
          hop_rel = hop_defn.children[segments[idx]]?
          return unknown_child_error(segments[idx], hop_defn) if hop_rel.nil?
          return Facet::ServiceError.new(404, "Not found") unless Helpers.lock_live_projection_for_update(db, domain, hop_rel.doctype, segments[idx + 1])
          current_doctype = hop_rel.doctype
          idx += 2
        end
        nil
      end

      # Renders the non-disclosing 404 for an unknown nested relation. The
      # message names the relations the resolved definition accepts, so a
      # caller can correct the path without probing. Children are always
      # listed; `include_sidecars` / `include_actions` add the other
      # relation kinds at the routes that dispatch them.
      private def self.unknown_child_error(
        relation : String,
        defn : Facet::Doctype::DoctypeDefinition,
        include_sidecars : Bool = false,
        include_actions : Bool = false,
      ) : Facet::ServiceError
        relations = defn.children.keys
        relations += defn.sidecars.keys if include_sidecars
        relations += defn.actions.keys if include_actions
        relations = relations.uniq.sort!
        detail = relations.empty? ? "none" : relations.join(", ")
        Facet::ServiceError.new(404, "Unknown child '#{relation}' — valid relations: #{detail}")
      end

      # PATCH: update a specific child document (even segments = specific target).
      private def self.rest_patch(env, domain, root_doctype, root_id, segments)
        return unless Helpers.require_csrf(env)

        body = Helpers.parse_body(env)
        if body.nil? || body.empty?
          Helpers.write_json_error(env, 422, "Request body is required")
          return
        end
        return if reject_unsupported_body(env, body)
        if segments.size.odd?
          Helpers.write_json_error(env, 400, "PATCH requires a specific child document id (got a collection path)")
          return
        end

        handled = render_sidecar_write(env, domain, root_doctype, root_id, segments, "patch", body)
        return handled if handled

        target = resolve_child_for_write(env, domain, root_doctype, root_id, segments)
        return if target.nil?
        t_domain, t_doctype, t_id = target

        result = Database.with_transaction do |db|
          Helpers.lock_with_chain(db, t_domain, t_doctype, t_id)
          Facet::Document::Update.call(db, t_domain, t_doctype, t_id, body, Helpers.auth_context(env), authorize_path: composition_path(domain, root_doctype, root_id, segments))
        end
        Event::Publisher.flush
        Helpers.write_result(env, result)
      end

      # DELETE: soft-delete a specific child document (even segments = specific target).
      private def self.rest_delete(env, domain, root_doctype, root_id, segments)
        return unless Helpers.require_csrf(env)

        if segments.size.odd?
          Helpers.write_json_error(env, 400, "DELETE requires a specific child document id (got a collection path)")
          return
        end

        handled = render_sidecar_write(env, domain, root_doctype, root_id, segments, "delete", "")
        return handled if handled

        target = resolve_child_for_write(env, domain, root_doctype, root_id, segments)
        return if target.nil?
        t_domain, t_doctype, t_id = target

        result = Database.with_transaction do |db|
          next Facet::ServiceError.new(404, "Not found") unless Helpers.lock_with_chain(db, t_domain, t_doctype, t_id)
          Facet::Document::Delete.call(db, t_domain, t_doctype, t_id, Helpers.auth_context(env), authorize_path: composition_path(domain, root_doctype, root_id, segments))
        end
        Event::Publisher.flush
        Helpers.write_result(env, result)
      end

      # Writes the 200 list response tail shared by the child and sidecar
      # list renders: ETag header, capped count with the Result's `more`
      # flag, and the projection list. These lists are unpaginated (page 1,
      # 1000 items), so the count starts at offset 0.
      # Returns the response body string (the body is already on the
      # response, same convention as `Helpers.write_json`).
      private def self.write_list_result(env, result : Facet::Document::List::Result, etag : String) : String
        env.response.status_code = 200
        env.response.content_type = "application/json"
        Helpers.set_etag_header(env, etag)
        count, _ = Helpers.capped_count(result.total, 0)
        {data: Helpers.projection_list(result.items), meta: {count: count, more: result.more}}.to_json
      end

      # ── Resolver helpers ────────────────────────────────────────────────

      # Resolves the child target for a write operation (PATCH/DELETE) and
      # applies the non-disclosing gates: an unresolved path writes the
      # resolver's error, and a target whose `parent_id` meta does not match
      # the expected parent writes the 404. Returns `{domain, doctype, id}`
      # for a writable target, or `nil` after the error response is written.
      private def self.resolve_child_for_write(env, domain, root_doctype, root_id, segments) : {String, String, String}?
        t_domain, t_doctype, t_id, err = resolve_child_target(domain, root_doctype, root_id, segments)
        if err
          Helpers.write_json_error(env, err[:status], err[:message])
          return nil
        end

        expected_parent_id = resolve_expected_parent_id(domain, root_doctype, root_id, segments)
        if expected_parent_id && !child_belongs_to_parent?(t_domain.as(String), t_doctype.as(String), t_id.as(String), expected_parent_id)
          Helpers.write_json_error(env, 404, "Not found")
          return nil
        end

        {t_domain.as(String), t_doctype.as(String), t_id.as(String)}
      end

      private def self.resolve_immediate_parent(domain, root_doctype, root_id, segments)
        if segments.size <= 1
          doctype_id = "#{domain}.#{root_doctype}"
          defn = Database.with_db(:read_only) { |db| Helpers.fetch_doctype_defn(db, doctype_id) }
          if defn.nil?
            return {nil, nil, {status: 404, message: "Unknown doctype: #{doctype_id}"}}
          end
          return {defn, root_id, nil}
        end

        parent_segments = segments[0...-1]
        result = Database.with_db(:read_only) { |db| NestedPathResolver.resolve(db, domain, root_doctype, root_id, parent_segments) }
        case result
        in NestedPathResolver::Resolved
          {result.parent_defn, result.parent_id, nil}
        in Facet::ServiceError
          {nil, nil, {status: result.status, message: result.message}}
        end
      end

      private def self.resolve_child_target(domain, root_doctype, root_id, rest_segments)
        result = Database.with_db(:read_only) { |db| NestedPathResolver.resolve(db, domain, root_doctype, root_id, rest_segments) }
        case result
        in NestedPathResolver::Resolved then {result.target.domain, result.target.doc_type, result.target.doc_id, nil}
        in Facet::ServiceError          then {nil, nil, nil, {status: result.status, message: result.message}}
        end
      end

      # The composition path of a nested child target, from the aggregate
      # root: `[root_doctype, child_doctype, ...]` — one doctype per
      # relationship segment. This is the path the RBAC gate checks on the
      # nested routes (the flat route keeps the bare child path). The
      # segments alternate relationship/id, so every even segment names a
      # relationship; the doctype chain re-walks the definitions in one
      # read-only pass. Returns `nil` on an unresolvable path (the caller
      # surfaces the resolution error separately).
      private def self.composition_path(domain, root_doctype, root_id, rest_segments) : Array(String)?
        Database.with_db(:read_only) do |db|
          path = [root_doctype]
          current_doctype = root_doctype
          idx = 0
          while idx < rest_segments.size
            defn = Helpers.fetch_doctype_defn(db, "#{domain}.#{current_doctype}")
            return nil if defn.nil?
            child = defn.children[rest_segments[idx]]?
            return nil if child.nil?
            path << child.doctype
            current_doctype = child.doctype
            idx += 2
          end
          path
        end
      end

      private def self.resolve_expected_parent_id(domain, root_doctype, root_id, segments) : String?
        return nil if segments.empty?
        return nil unless segments.size.even?

        if segments.size == 2
          return root_id
        end

        segments[-3]
      end

      private def self.child_belongs_to_parent?(domain, doc_type, doc_id, expected_parent_id) : Bool
        Database.with_db(:read_only) do |db|
          proj = Facet::Mutation::Client.fetch_projection(db, domain, doc_type, doc_id)
          meta_h = proj.meta.as_h?
          if meta_h && (pid = meta_h["parent_id"]?)
            pid.raw == expected_parent_id
          else
            false
          end
        rescue
          false
        end
      end
    end
  end
end

# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"

require "../../../app/grants_validator"
require "../../../grants/validator"
require "../../../hooks/validator"
require "../../../secrets/adoption"

module Facet
  module Domain
    module Portable
      module Import
        # Runs the secret-leaf gate for one bundled document row (B-370).
        # A bundled row bypasses the write door, so the type-layer check
        # (`SecretType#validate`) and the adoption step
        # (`Secrets::Adoption.call`) never ran on it — a plaintext string
        # or a forged marker landed verbatim in `projections.content`, the
        # event log, and export. The gate mirrors the write door's order:
        # the shape check first (names the field), then adoption, which
        # verifies markers against stored slots and routes stage handles
        # through the staging table. A bundle carries no secret material:
        # a handle has no staging row on the importing instance (the
        # staging row is short-lived and stager-bound, and the import
        # actioner is not an account), and a marker without a matching
        # slot row is a forged state. Any refusal raises `ImportError`, so
        # the caller's transaction rolls the whole import back — the
        # payload is never redacted or rewritten, because `mutations` is
        # the replay source. Returns the adopted content (unchanged on a
        # passing bundle).
        private def self.validate_secret_gate!(
          txn : DB::Connection,
          defn : Doctype::DoctypeDefinition,
          target_qualified : String,
          doc_id : String,
          content : JSON::Any,
          source_file : String?,
          actioner_id : String,
        ) : JSON::Any
          domain, _, doc_type = target_qualified.partition('.')

          errors = [] of Facet::ValidationError
          collect_secret_leaf_errors(defn, content, errors)
          raise_row_error!(target_qualified, doc_id, source_file, "Secret field validation failed", errors)

          Secrets::Adoption.call(txn, defn, content, domain, doc_type, doc_id, actioner_id)
        rescue e : Secrets::Adoption::AdoptionError
          where = source_file ? " from #{source_file}" : ""
          raise ImportError.new(
            e.error.status,
            "Bundle document '#{target_qualified}##{doc_id}'#{where}: secret adoption failed: #{e.error.message}",
          )
        end

        # Collects the shape errors of every secret leaf — the same check
        # `Document::Validation` runs on the write door, confined to the
        # placements the definition allows (top-level fields and one-level
        # object properties). An explicit null skips: the shared
        # optional-field skip accepts it on the write door, and adoption
        # reads it as clear intent.
        private def self.collect_secret_leaf_errors(
          defn : Doctype::DoctypeDefinition,
          content : JSON::Any,
          errors : Array(Facet::ValidationError),
        ) : Nil
          root = content.as_h? || return
          defn.fields.each do |name, field|
            case field.type.try(&.type_name)
            when "secret"
              validate_secret_leaf(root[name]?, field, name, errors)
            when "object"
              props = field.properties || next
              nested = root[name]?.try(&.as_h?) || next
              props.each do |prop, sub|
                next if sub.type.try(&.type_name) != "secret"
                validate_secret_leaf(nested[prop]?, sub, "#{name}.#{prop}", errors)
              end
            end
          end
        end

        private def self.validate_secret_leaf(
          value : JSON::Any?,
          field : Doctype::FieldDefinition,
          path : String,
          errors : Array(Facet::ValidationError),
        ) : Nil
          return if value.nil? || value.raw.nil?
          field.type.try(&.validate(value, field, path, errors))
        end

        # Runs the authoring gate for the bundled `core.Domain` row — the
        # Runs the authoring gate for one bundled document row. Raises
        # `ImportError` (422) when the row fails; the message names the
        # doctype, the row id, and the first failing line. Runs before the
        # unique-constraint check — the same order `Document::Create` uses.
        private def self.validate_document_authoring!(
          txn : DB::Connection,
          target_qualified : String,
          doc_id : String,
          content : JSON::Any,
          meta : JSON::Any,
          source_file : String?,
        ) : Nil
          domain, _, doc_type = target_qualified.partition('.')

          if {domain, doc_type} == {"iam", "Roles"}
            perms_raw = content["permissions"]?.try(&.as_a) || [] of JSON::Any
            errors = RBAC::Validator.validate_permissions_for(perms_raw, txn)
            raise_row_error!(target_qualified, doc_id, source_file, "RBAC permission validation failed", errors)
            return
          end

          if {domain, doc_type} == {"core", "DomainGrant"}
            parent_domain = grant_parent_domain(meta)
            return if parent_domain.nil?
            errors = [] of Facet::ValidationError
            Grants::Validator.validate(
              parent_domain,
              content["consumer_domain"]?.try(&.as_s?),
              content["resources"]?,
              errors,
            )
            raise_row_error!(target_qualified, doc_id, source_file, "Grant validation failed", errors)
            return
          end

          if {domain, doc_type} == {"app", "App"}
            errors = App::GrantsAuthoring.validate(content["grants"]?)
            raise_row_error!(target_qualified, doc_id, source_file, "Grant validation failed", errors)
            return
          end

          if {domain, doc_type} == {"core", "CollectionView"}
            parent_id = meta.as_h?.try(&.["parent_id"]?).try(&.as_s?)
            template = content.dig?("config", "calendar", "title_template").try(&.as_s?)
            if parent_id && template
              case defn = Doctype::DefinitionStore.fetch!(txn, parent_id)
              when Doctype::DoctypeDefinition
                errors = Doctype::CollectionView::TitleTemplate.validate(template, defn)
                raise_row_error!(target_qualified, doc_id, source_file, "Collection view validation failed", errors)
              else
                # An unresolvable parent definition skips the check — the
                # same tolerance the API create path applies.
              end
            end
          end
        end

        # Runs the authoring gate for the bundled `core.Domain` row — the
        # checks `Document::Update#validate_rbac_definitions?` runs on a
        # domain save: context sets (SQL-safe field names, predicate
        # grammar) and declared hooks (script compile, required export,
        # cron shape). An unsafe field name is a SQL-injection vector, so
        # this gate runs even though the API's domain-create path checks
        # context sets only. Raises `ImportError` (422) naming the domain.
        private def self.validate_domain_authoring!(
          target_domain : String,
          content : JSON::Any,
        ) : Nil
          parsed_sets = begin
            RBAC::ContextResolver.extract_context_sets(content)
          rescue ex : ArgumentError
            raise ImportError.new(
              422,
              "core.Domain '#{target_domain}': invalid context_sets: #{ex.message}",
            )
          end

          errors = [] of Facet::ValidationError
          RBAC::Validator.validate_context_set_definitions(content, target_domain, parsed_sets, errors)
          unless errors.empty?
            raise ImportError.new(
              422,
              "core.Domain '#{target_domain}': RBAC context set validation failed: #{errors.first.message}",
              details: errors,
            )
          end

          hooks, parse_errors = Facet::Hooks::Definition.parse(content)
          hook_errors = parse_errors + Facet::Hooks::Validator.validate(hooks)
          unless hook_errors.empty?
            raise ImportError.new(
              422,
              "core.Domain '#{target_domain}': Domain hooks validation failed: #{hook_errors.first.message}",
              details: hook_errors,
            )
          end
        end

        # Derives a `core.DomainGrant` row's parent (producer) domain from
        # `meta.parent_id` — the same derivation `Document::Create` and
        # `Document::Update` run. Returns `nil` when the row carries no
        # parent; the grant gate then skips, like the API.
        private def self.grant_parent_domain(meta : JSON::Any) : String?
          parent_id = meta.as_h?.try(&.["parent_id"]?).try(&.as_s?)
          return nil if parent_id.nil?
          parent_id.starts_with?("core.Domain.") ? parent_id["core.Domain.".size..] : parent_id
        end

        # Raises the row-level `ImportError`. No-op on an empty error list.
        # The message shape matches the unique-constraint error in
        # `create_document`: doctype, row id, the bundle-relative file, the
        # failure label, then the first structured message. The full detail
        # list rides on `details` for the CLI's indented printout.
        private def self.raise_row_error!(
          target_qualified : String,
          doc_id : String,
          source_file : String?,
          label : String,
          errors : Array(Facet::ValidationError),
        ) : Nil
          return if errors.empty?
          where = source_file ? " from #{source_file}" : ""
          raise ImportError.new(
            422,
            "Bundle document '#{target_qualified}##{doc_id}'#{where}: #{label}: #{errors.first.message}",
            details: errors,
          )
        end
      end
    end
  end
end

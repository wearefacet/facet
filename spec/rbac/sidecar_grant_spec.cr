# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"

# ── Helpers (shared with the write/read enforcer specs) ──────────────────────
#
# These mirror the role/account helpers in `write_enforcer_spec.cr` so the
# sidecar grant specs build the same IAM projection shape. The
# `authorize_sidecar_create` / `sidecar_authorized?` methods are pure
# permission-path checks (no doctype store lookup, no content fetch), so no
# sidecar doctype definition needs to exist for the unit specs.

def sidecar_role_ctx(db, role_id, account_id) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id)
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Builds a permission JSON hash. The `scope` argument is optional.
module Facet::RBAC
  describe "sidecar cross-domain nested grant" do
    # Host identity is `hr.Employee`; sidecar identity is `core.Comment`.
    # The nested grant grammar is `hr.Employee.Comment`. Flat grants on the
    # sidecar doctype (`core.Comment`) do NOT authorise the nested route —
    # they serve the flat `/Api/core/Comment` endpoint only. The nested
    # path is prefix-matched, so a host permission implies the nested grant
    # for the same action (`read hr.Employee` ⇒ `read hr.Employee.Comment`).

    # ── WriteEnforcer.authorize_sidecar_create ───────────────────────────

    describe WriteEnforcer do
      describe ".authorize_sidecar_create" do
        it "allows the system bypass" do
          with_db do |db|
            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", AuthContext.system
            )
            result.should be_true
          end
        end

        it "authorises via the nested grant hr.Employee.Comment" do
          with_db do |db|
            create_role_projection(db, "nested_creator", [
              permission_json("create", "hr.Employee.Comment"),
            ])
            ctx = sidecar_role_ctx(db, "nested_creator", "01NESTED")

            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_true
          end
        end

        it "authorises via the host grant prefix (create hr.Employee)" do
          # Permission#matches_path? is prefix-based, so a host `create`
          # grant implies the nested sidecar create — host writers can
          # comment without an explicit nested line.
          with_db do |db|
            create_role_projection(db, "host_creator", [
              permission_json("create", "hr.Employee"),
            ])
            ctx = sidecar_role_ctx(db, "host_creator", "01HOSTCREATE")

            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_true
          end
        end

        it "denies the flat grant core.Comment (flat grants serve the flat endpoint only)" do
          with_db do |db|
            create_role_projection(db, "flat_creator", [
              permission_json("create", "core.Comment"),
            ])
            ctx = sidecar_role_ctx(db, "flat_creator", "01FLAT")

            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_false
          end
        end

        it "authorises when the nested grant carries a named scope alias" do
          # A scoped nested match authorises the create action itself; the
          # host read gate in the handler restricts to reachable host records.
          with_db do |db|
            create_role_projection(db, "scoped_nested", [
              permission_json("create", "hr.Employee.Comment", "$mine"),
            ])
            ctx = sidecar_role_ctx(db, "scoped_nested", "01SCOPED")

            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_true
          end
        end

        it "denies when the role has no nested comment grant" do
          with_db do |db|
            create_role_projection(db, "reader_only", [
              permission_json("read", "hr.Employee"),
            ])
            ctx = sidecar_role_ctx(db, "reader_only", "01NOCREATE")

            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_false
          end
        end

        it "denies when the nested grant is for a different host doctype" do
          # `create hr.Department.Comment` does NOT cover `hr.Employee.Comment`
          # — path matching is exact-prefix, not cross-doctype wildcard.
          with_db do |db|
            create_role_projection(db, "wrong_host", [
              permission_json("create", "hr.Department.Comment"),
            ])
            ctx = sidecar_role_ctx(db, "wrong_host", "01WRONGHOST")

            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_false
          end
        end

        it "denies when the nested grant is in a different host domain" do
          with_db do |db|
            create_role_projection(db, "wrong_domain", [
              permission_json("create", "sales.Employee.Comment"),
            ])
            ctx = sidecar_role_ctx(db, "wrong_domain", "01WRONGDOM")

            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_false
          end
        end

        it "denies when the host read permission exists but no comment grant" do
          # `read hr.Employee` happens to match the host doctype prefix
          # (["Employee"] is a prefix of ["Employee", "Comment"]), but the
          # action is `read`, not `create` — the nested create grant must
          # name `create` as its action.
          with_db do |db|
            create_role_projection(db, "host_reader", [
              permission_json("read", "hr.Employee"),
            ])
            ctx = sidecar_role_ctx(db, "host_reader", "01HOSTREAD")

            result = WriteEnforcer.authorize_sidecar_create(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_false
          end
        end
      end
    end

    # ── ReadEnforcer.sidecar_authorized? ─────────────────────────────────

    describe ReadEnforcer do
      describe ".sidecar_authorized?" do
        it "allows the system bypass" do
          with_db do |db|
            result = ReadEnforcer.sidecar_authorized?(
              db, "hr", "Employee", "core", "Comment", AuthContext.system
            )
            result.should be_true
          end
        end

        it "authorises via the nested grant hr.Employee.Comment" do
          with_db do |db|
            create_role_projection(db, "nested_reader", [
              permission_json("read", "hr.Employee.Comment"),
            ])
            ctx = sidecar_role_ctx(db, "nested_reader", "01NREAD")

            result = ReadEnforcer.sidecar_authorized?(
              db, "hr", "Employee", "core", "Comment", ctx
            )
            result.should be_true
          end
        end

        it "authorises via the host grant prefix (read hr.Employee)" do
          # `read hr.Employee` prefix-matches `hr.Employee.Comment`, so a
          # caller who can read the host inherently holds the nested sidecar
          # read at the route gate.
          with_db do |db|
            create_role_projection(db, "host_reader", [
              permission_json("read", "hr.Employee"),
            ])
            ctx = sidecar_role_ctx(db, "host_reader", "01HOSTREAD")

            result = ReadEnforcer.sidecar_authorized?(db, "hr", "Employee", "core", "Comment", ctx)
            result.should be_true
          end
        end

        it "denies the flat grant core.Comment (flat grants serve the flat endpoint only)" do
          with_db do |db|
            create_role_projection(db, "flat_reader", [
              permission_json("read", "core.Comment"),
            ])
            ctx = sidecar_role_ctx(db, "flat_reader", "01FLATR")

            result = ReadEnforcer.sidecar_authorized?(db, "hr", "Employee", "core", "Comment", ctx)
            result.should be_false
          end
        end

        it "denies when the role has no nested comment grant" do
          with_db do |db|
            create_role_projection(db, "no_read", [
              permission_json("create", "hr.Employee.Comment"),
            ])
            ctx = sidecar_role_ctx(db, "no_read", "01NOREAD")

            result = ReadEnforcer.sidecar_authorized?(db, "hr", "Employee", "core", "Comment", ctx)
            result.should be_false
          end
        end
      end
    end
  end
end

# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/mutation/client"
require "../../src/document"
require "../support/rbac_helper"

# ── Specs ────────────────────────────────────────────────────────────

module Facet::RBAC
  describe ReadEnforcer do
    before_each do
      with_db do |db|
        ensure_domain(db, "crm")
        create_rbac_project_doctype(db)
      end
    end

    # ── authorized? (single-doc read) ─────────────────────────────────────

    describe ".authorized?" do
      it "allows system bypass" do
        with_db do |db|
          doc_id = create_rbac_test_doc(db, "crm", "Project")
          expect_rbac_authorized(db, "crm", "Project", doc_id, AuthContext.system)
        end
      end

      it "denies when role has no matching permissions" do
        with_db do |db|
          create_role_projection(db, "no_perms")
          create_account_projection(db, "account_no_perms", ["no_perms"])
          doc_id = create_rbac_test_doc(db, "crm", "Project")

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "no_perms")
          )
          ctx = AuthContext.authenticated("account_no_perms", role)
          expect_rbac_denied(db, "crm", "Project", doc_id, ctx)
        end
      end

      it "allows when role has an unrestricted read permission" do
        with_db do |db|
          create_role_projection(db, "unscoped_reader", [
            permission_json("read", "crm.Project"),
          ])
          create_account_projection(db, "reader_1", ["unscoped_reader"])
          doc_id = create_rbac_test_doc(db, "crm", "Project")

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "unscoped_reader")
          )
          ctx = AuthContext.authenticated("reader_1", role)
          expect_rbac_authorized(db, "crm", "Project", doc_id, ctx)
        end
      end

      it "allows when the named scope's $self predicate matches" do
        with_db do |db|
          create_role_projection(db, "mine_reader", [
            permission_json("read", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "account_owns", ["mine_reader"])
          account_id = "account_owns"
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "iam.Account.#{account_id}"})

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "mine_reader")
          )
          ctx = AuthContext.authenticated(account_id, role)
          expect_rbac_authorized(db, "crm", "Project", doc_id, ctx)
        end
      end

      it "allows when the named scope's $self predicate matches the bare account id" do
        # A plain string owner field stores the bare id (the documented
        # `ctx.root.owner_id = ctx.actor.id` create-hook recipe) — the
        # `$mine` scope must match it exactly as it matches the qualified
        # reference form above.
        with_db do |db|
          create_role_projection(db, "mine_reader_bare", [
            permission_json("read", "crm.Project", "$mine"),
          ])
          account_id = "account_owns_bare"
          create_account_projection(db, account_id, ["mine_reader_bare"])
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => account_id})

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "mine_reader_bare")
          )
          ctx = AuthContext.authenticated(account_id, role)
          expect_rbac_authorized(db, "crm", "Project", doc_id, ctx)
        end
      end

      it "denies when the named scope's $self predicate does not match" do
        with_db do |db|
          create_role_projection(db, "mine_reader", [
            permission_json("read", "crm.Project", "$mine"),
          ])
          create_account_projection(db, "not_owner", ["mine_reader"])
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "someone_else"})

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "mine_reader")
          )
          ctx = AuthContext.authenticated("not_owner", role)
          expect_rbac_denied(db, "crm", "Project", doc_id, ctx)
        end
      end

      it "allows with a literal named scope match" do
        with_db do |db|
          create_role_projection(db, "dept_reader", [
            permission_json("read", "crm.Project", "$engineering"),
          ])
          create_account_projection(db, "eng_account", ["dept_reader"])
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"department" => "engineering"})

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "dept_reader")
          )
          ctx = AuthContext.authenticated("eng_account", role)
          expect_rbac_authorized(db, "crm", "Project", doc_id, ctx)
        end
      end

      it "denies with a literal named scope mismatch" do
        with_db do |db|
          create_role_projection(db, "dept_reader", [
            permission_json("read", "crm.Project", "$engineering"),
          ])
          create_account_projection(db, "mrk_account", ["dept_reader"])
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"department" => "marketing"})

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "dept_reader")
          )
          ctx = AuthContext.authenticated("mrk_account", role)
          expect_rbac_denied(db, "crm", "Project", doc_id, ctx)
        end
      end

      it "fails closed when the named scope is not declared on the doctype" do
        with_db do |db|
          create_role_projection(db, "ghost_reader", [
            permission_json("read", "crm.Project", "$ghost"),
          ])
          create_account_projection(db, "ghost_account", ["ghost_reader"])
          doc_id = create_rbac_test_doc(db, "crm", "Project")

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "ghost_reader")
          )
          ctx = AuthContext.authenticated("ghost_account", role)
          expect_rbac_denied(db, "crm", "Project", doc_id, ctx)
        end
      end

      # ── multi-alias OR semantics ─────────────────────────────────────────────

      it "matches when ANY alias in a multi-scope permission matches (OR)" do
        with_db do |db|
          create_role_projection(db, "mine_or_global_reader", [
            permission_json("read", "crm.Project", ["$mine", "$global"]),
          ])
          create_account_projection(db, "mine_account", ["mine_or_global_reader"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "mine_or_global_reader")
          )
          ctx = AuthContext.authenticated("mine_account", role)

          # $mine matches — user owns the doc.
          mine_doc = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "iam.Account.mine_account"})
          expect_rbac_authorized(db, "crm", "Project", mine_doc, ctx)

          # $global matches — owner_id is absent on the projection.
          global_doc = create_rbac_test_doc(db, "crm", "Project")
          expect_rbac_authorized(db, "crm", "Project", global_doc, ctx)
        end
      end

      it "denies when NONE of the aliases in a multi-scope permission match" do
        with_db do |db|
          create_role_projection(db, "mine_or_global_reader", [
            permission_json("read", "crm.Project", ["$mine", "$global"]),
          ])
          create_account_projection(db, "other_account", ["mine_or_global_reader"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "mine_or_global_reader")
          )
          ctx = AuthContext.authenticated("other_account", role)

          # Owned by someone else — neither $mine nor $global matches.
          someone_elses = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "someone_else"})
          expect_rbac_denied(db, "crm", "Project", someone_elses, ctx)
        end
      end

      it "fails closed when ANY alias in a multi-scope permission is undeclared" do
        with_db do |db|
          create_role_projection(db, "mine_or_ghost_reader", [
            permission_json("read", "crm.Project", ["$mine", "$ghost"]),
          ])
          create_account_projection(db, "ghost_combo_account", ["mine_or_ghost_reader"])
          doc_id = create_rbac_test_doc(db, "crm", "Project", {"owner_id" => "ghost_combo_account"})

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "mine_or_ghost_reader")
          )
          ctx = AuthContext.authenticated("ghost_combo_account", role)
          expect_rbac_denied(db, "crm", "Project", doc_id, ctx)
        end
      end
    end

    # ── list_where_clauses ────────────────────────────────────────────────

    describe ".list_where_clauses" do
      it "returns empty restrictions for system bypass" do
        with_db do |db|
          clauses, params = ReadEnforcer.list_where_clauses(db, "crm", "Project", AuthContext.system)
          clauses.should be_empty
          params.should be_empty
        end
      end

      it "returns 1=0 when no matching permissions" do
        with_db do |db|
          create_role_projection(db, "no_access")
          create_account_projection(db, "blocked", ["no_access"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "no_access")
          )
          ctx = AuthContext.authenticated("blocked", role)
          clauses, _params = ReadEnforcer.list_where_clauses(db, "crm", "Project", ctx)
          clauses.should eq(["1=0"])
        end
      end

      it "returns empty restrictions for unrestricted read permission" do
        with_db do |db|
          create_role_projection(db, "full_access", [
            permission_json("read", "crm.Project"),
          ])
          create_account_projection(db, "admin", ["full_access"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "full_access")
          )
          ctx = AuthContext.authenticated("admin", role)
          clauses, _params = ReadEnforcer.list_where_clauses(db, "crm", "Project", ctx)
          clauses.should be_empty
        end
      end

      it "injects $self from the named scope as SQL parameters (both principal forms)" do
        with_db do |db|
          create_role_projection(db, "mine_list", [
            permission_json("read", "crm.Project", "$mine"),
          ])
          account_id = "mine_list_account"
          create_account_projection(db, account_id, ["mine_list"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "mine_list")
          )
          ctx = AuthContext.authenticated(account_id, role)
          clauses, params = ReadEnforcer.list_where_clauses(db, "crm", "Project", ctx)
          clauses.size.should eq(1)
          clauses.first.should contain("owner_id")
          clauses.first.should contain("$1")
          # `$self` binds both accepted principal forms: the bare id (what
          # a plain string owner field stores) and the qualified reference
          # form (what a reference field targeting `iam.Account` stores).
          params.should eq([account_id, RBAC.qualify_principal(account_id)])
        end
      end

      it "injects a literal named scope value as a SQL parameter" do
        with_db do |db|
          create_role_projection(db, "dept_list", [
            permission_json("read", "crm.Project", "$engineering"),
          ])
          create_account_projection(db, "eng_list", ["dept_list"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "dept_list")
          )
          ctx = AuthContext.authenticated("eng_list", role)
          clauses, params = ReadEnforcer.list_where_clauses(db, "crm", "Project", ctx)
          clauses.size.should eq(1)
          clauses.first.should contain("department")
          clauses.first.should contain("$1")
          params.should eq(["engineering"])
        end
      end

      it "fails closed with 1=0 when the named scope is undeclared" do
        with_db do |db|
          create_role_projection(db, "ghost_list", [
            permission_json("read", "crm.Project", "$ghost"),
          ])
          create_account_projection(db, "ghost_list_account", ["ghost_list"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "ghost_list")
          )
          ctx = AuthContext.authenticated("ghost_list_account", role)
          clauses, _params = ReadEnforcer.list_where_clauses(db, "crm", "Project", ctx)
          # A single failed-scope clause is parenthesised when OR-combined.
          clauses.should eq(["(1=0)"])
        end
      end

      it "emits a parenthesised OR group for a multi-scope permission" do
        with_db do |db|
          create_role_projection(db, "mine_or_global_list", [
            permission_json("read", "crm.Project", ["$mine", "$global"]),
          ])
          account_id = "mine_or_global_list_account"
          create_account_projection(db, account_id, ["mine_or_global_list"])

          role = ActiveRole.from_projection_content(
            Mutation::Client.fetch_content(db, "iam", "Role", "mine_or_global_list")
          )
          ctx = AuthContext.authenticated(account_id, role)
          clauses, params = ReadEnforcer.list_where_clauses(db, "crm", "Project", ctx)
          # One outer clause wrapping the per-permission OR group.
          clauses.size.should eq(1)
          sql = clauses.first
          # The SQL contains both a $self equality and an IS NULL, joined by OR
          # inside the per-permission group, then wrapped by list_where_clauses.
          sql.should contain("owner_id")
          sql.should contain("IS NULL")
          sql.should contain(" OR ")
          # `$self` binds both accepted principal forms: the bare id (what
          # a plain string owner field stores) and the qualified reference
          # form (what a reference field targeting `iam.Account` stores).
          params.should eq([account_id, RBAC.qualify_principal(account_id)])
        end
      end
    end

    # ── structural metadata gate (B-86) ─────────────────────────────────────

    describe ".list_where_clauses — structural metadata" do
      it "serves the definitions the caller holds grants on (no core.DocType line)" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([
            rbac_perm("read", "iam.Account"),
            rbac_perm("create", "iam.Account"),
            rbac_perm("update", "iam.Account"),
            rbac_perm("delete", "iam.Account"),
            rbac_perm("read", "iam.Roles"),
            rbac_perm("read", "iam.LoginEvent"),
          ]))
          clauses, params = ReadEnforcer.list_where_clauses(db, "core", "DocType", ctx)
          clauses.size.should eq(1)
          clauses.first.should contain("id = $1")
          clauses.first.should contain("id = $2")
          clauses.first.should contain("id = $3")
          # The four iam.Account lines dedupe to one definition id.
          params.should eq(["iam.Account", "iam.Roles", "iam.LoginEvent"])
        end
      end

      it "returns no restriction for a wildcard read role" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "*.*")]))
          clauses, params = ReadEnforcer.list_where_clauses(db, "core", "DocType", ctx)
          clauses.should be_empty
          params.should be_empty
        end
      end

      it "subtracts two-segment except entries on a domain-wide line" do
        with_db do |db|
          perm = Permission.new(
            action: "read", domain: "iam", path: [] of String,
            except: ["iam.Roles", "iam.LoginEvent.Sub"],
          )
          ctx = AuthContext.authenticated("acc_meta", rbac_role([perm]))
          clauses, params = ReadEnforcer.list_where_clauses(db, "core", "DocType", ctx)
          clauses.size.should eq(1)
          clauses.first.should contain("split_part(id, '.', 1) = $1")
          clauses.first.should contain("id != $2")
          # A deeper entry targets child rows of a doctype, never the
          # definition itself.
          clauses.first.should_not contain("LoginEvent.Sub")
          params.should eq(["iam", "iam.Roles"])
        end
      end

      it "expands a domain-wide line to the whole domain" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "iam")]))
          clauses, params = ReadEnforcer.list_where_clauses(db, "core", "DocType", ctx)
          clauses.size.should eq(1)
          clauses.first.should contain("split_part(id, '.', 1) = $1")
          params.should eq(["iam"])
        end
      end

      it "returns 1=0 for a nested-path-only role (no definition reach)" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "hr.Employee.Comment")]))
          clauses, _params = ReadEnforcer.list_where_clauses(db, "core", "DocType", ctx)
          clauses.should eq(["1=0"])
        end
      end

      it "serves the domains the caller holds grants inside" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([
            rbac_perm("read", "iam.Account"),
            rbac_perm("create", "iam.Roles"),
          ]))
          clauses, params = ReadEnforcer.list_where_clauses(db, "core", "Domain", ctx)
          clauses.size.should eq(1)
          clauses.first.should contain("id = $1")
          params.should eq(["iam"])
        end
      end

      it "returns 1=0 for a caller with no grants" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([] of Permission))
          clauses, _params = ReadEnforcer.list_where_clauses(db, "core", "DocType", ctx)
          clauses.should eq(["1=0"])
          clauses, _params = ReadEnforcer.list_where_clauses(db, "core", "Domain", ctx)
          clauses.should eq(["1=0"])
        end
      end
    end

    describe ".authorized? — structural metadata" do
      it "reads a granted definition without a core.DocType read line" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "iam.Account")]))
          expect_rbac_authorized(db, "core", "DocType", "iam.Account", ctx)
        end
      end

      it "denies an ungranted definition (non-disclosing)" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "iam.Account")]))
          expect_rbac_denied(db, "core", "DocType", "iam.Roles", ctx)
        end
      end

      it "does not expose the parent definition for a nested-path grant" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "hr.Employee.Comment")]))
          expect_rbac_denied(db, "core", "DocType", "hr.Employee", ctx)
        end
      end

      it "honours except carve-outs on the single read" do
        with_db do |db|
          perm = Permission.new(
            action: "read", domain: "iam", path: [] of String,
            except: ["iam.Roles"],
          )
          ctx = AuthContext.authenticated("acc_meta", rbac_role([perm]))
          expect_rbac_authorized(db, "core", "DocType", "iam.Account", ctx)
          expect_rbac_denied(db, "core", "DocType", "iam.Roles", ctx)
        end
      end

      it "reads a domain row the caller holds grants inside" do
        with_db do |db|
          ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "iam.Account")]))
          expect_rbac_authorized(db, "core", "Domain", "iam", ctx)
          expect_rbac_denied(db, "core", "Domain", "crm", ctx)
        end
      end
    end

    describe ".read_denied? — structural metadata" do
      it "mirrors the list gate for the structural doctypes" do
        ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "iam.Account")]))
        ReadEnforcer.read_denied?("core", "DocType", ctx).should be_false
        ReadEnforcer.read_denied?("core", "Domain", ctx).should be_false
        ReadEnforcer.read_denied?("crm", "Project", ctx).should be_true
      end
    end

    # ── mask_content ──────────────────────────────────────────────────────

    describe ".mask_content" do
      it "returns content unchanged for system principal" do
        content = JSON.parse(%({"name": "alice", "ssn": "123-45-6789"}))
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Person", domain: "hr", schema_version: 1,
          fields: {
            "name" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
            "ssn"  => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"), tags: ["confidential"]),
          },
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
        )
        masked = ReadEnforcer.mask_content(content, AuthContext.system, defn)
        masked.should eq(content)
      end

      it "hides fields tagged with tags not in visible_tags" do
        content = JSON.parse(%({"name": "alice", "ssn": "123-45-6789"}))
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Person", domain: "hr", schema_version: 1,
          fields: {
            "name" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
            "ssn"  => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"), tags: ["confidential"]),
          },
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
        )
        role = ActiveRole.new(
          role_id: "basic",
          visible_tags: Set{"default"},
          permissions: [] of Permission
        )
        ctx = AuthContext.authenticated("user", role)
        masked = ReadEnforcer.mask_content(content, ctx, defn)
        masked["name"]?.should eq(JSON.parse(%("alice")))
        masked["ssn"]?.should be_nil
      end

      it "shows all fields with wildcard tags" do
        content = JSON.parse(%({"name": "alice", "ssn": "123-45-6789"}))
        defn = Doctype::DoctypeDefinition.new(
          doctype: "Person", domain: "hr", schema_version: 1,
          fields: {
            "name" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
            "ssn"  => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"), tags: ["confidential"]),
          },
          children: {} of String => Facet::Doctype::ChildrenDefinition,
          actions: {} of String => Facet::Doctype::ActionDefinition,
        )
        role = ActiveRole.new(
          role_id: "admin",
          visible_tags: Set{"*"},
          permissions: [] of Permission
        )
        ctx = AuthContext.authenticated("admin_account", role)
        masked = ReadEnforcer.mask_content(content, ctx, defn)
        masked.should eq(content)
      end
    end
  end

  # Direct unit coverage for the module itself. A wildcard-domain line can
  # never reach MetadataGate through `ReadEnforcer` (it matches the generic
  # gate on `core.DocType`, which stays `Allowed`/`Scoped`), so those shapes
  # are exercised here against the module's own contract.
  describe MetadataGate do
    describe ".list_clause" do
      it "returns no restriction for a wildcard-domain read line" do
        ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "*.*")]))
        clauses, params = MetadataGate.list_clause("DocType", ctx, 1)
        clauses.should be_empty
        params.should be_empty

        clauses, params = MetadataGate.list_clause("Domain", ctx, 1)
        clauses.should be_empty
        params.should be_empty
      end

      it "subtracts two-segment except entries for a wildcard-domain line" do
        perm = Permission.new(
          action: "read", domain: "*", path: ["*"],
          except: ["core.SystemSettings", "iam.OIDCProvider", "core.Webhook.Comment"],
        )
        ctx = AuthContext.authenticated("acc_meta", rbac_role([perm]))
        clauses, params = MetadataGate.list_clause("DocType", ctx, 1)
        clauses.size.should eq(1)
        clauses.first.should contain("id != $1")
        clauses.first.should contain("id != $2")
        # A deeper entry targets child rows of a doctype, never the
        # definition itself.
        clauses.first.should_not contain("Webhook.Comment")
        params.should eq(["core.SystemSettings", "iam.OIDCProvider"])
      end

      it "dedupes repeated single-segment lines" do
        ctx = AuthContext.authenticated("acc_meta", rbac_role([
          rbac_perm("read", "iam.Account"),
          rbac_perm("update", "iam.Account"),
        ]))
        clauses, params = MetadataGate.list_clause("DocType", ctx, 1)
        clauses.size.should eq(1)
        clauses.first.should eq("(id = $1)")
        params.should eq(["iam.Account"])
      end

      it "starts placeholders at start_idx" do
        ctx = AuthContext.authenticated("acc_meta", rbac_role([
          rbac_perm("read", "iam.Account"),
          rbac_perm("read", "iam.Roles"),
        ]))
        clauses, params = MetadataGate.list_clause("DocType", ctx, 7)
        clauses.first.should eq("(id = $7 OR id = $8)")
        params.should eq(["iam.Account", "iam.Roles"])
      end
    end

    describe ".row_readable?" do
      it "honours except carve-outs for a wildcard-domain line" do
        perm = Permission.new(
          action: "read", domain: "*", path: ["*"],
          except: ["core.SystemSettings"],
        )
        ctx = AuthContext.authenticated("acc_meta", rbac_role([perm]))
        MetadataGate.row_readable?("DocType", "iam.Account", ctx).should be_true
        MetadataGate.row_readable?("DocType", "core.SystemSettings", ctx).should be_false
      end

      it "rejects a malformed definition id" do
        ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "iam.Account")]))
        MetadataGate.row_readable?("DocType", "nodot", ctx).should be_false
        MetadataGate.row_readable?("DocType", "", ctx).should be_false
      end

      it "rejects an empty domain id" do
        ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "iam.Account")]))
        MetadataGate.row_readable?("Domain", "", ctx).should be_false
      end
    end

    describe ".collection_reachable?" do
      it "answers true when any definition is reachable" do
        ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "iam.Account")]))
        MetadataGate.collection_reachable?("DocType", ctx).should be_true
        MetadataGate.collection_reachable?("Domain", ctx).should be_true
      end

      it "answers false for a nested-path-only role" do
        ctx = AuthContext.authenticated("acc_meta", rbac_role([rbac_perm("read", "hr.Employee.Comment")]))
        MetadataGate.collection_reachable?("DocType", ctx).should be_false
      end
    end
  end
end

# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../support/rbac_helper"

# Grant resolution engine.
#
# Covers the pure security logic exposed by `RBAC::GrantResolver`:
#   - `role_usable?(app, role)` — strict-ALL on required actions.
#   - `resolve(app, role)` — the granular grant ∩ role intersection.
#
# All cases construct their inputs from JSON literals and Crystal values;
# none touch the database. This mirrors the brief's instruction that the
# resolution engine be exhaustively unit-tested with zero HTTP involvement.

# ── Spec helpers ────────────────────────────────────────────────────────────

def app_scope(grants_json : String, app_id : String = "app_01")
  content = JSON.parse(%({"grants": #{grants_json}}))
  Facet::RBAC::AppScope.from_content(app_id, content)
end

# Decoded `EffectiveScope#entries` into a stable, comparable form for
# assertion: keyed by the original grant target, each entry contains the
# concrete (domain, path), the covered actions, and the scope aliases that
# survived on the matching role permissions. The shape emphasises what
# downstream enforcers will actually consult.
def decoded(scope : Facet::RBAC::EffectiveScope)
  scope.entries.map do |e|
    {
      target:  e.target,
      domain:  e.domain,
      path:    e.path,
      actions: e.actions.to_a.sort!,
      scopes:  e.permissions.flat_map(&.scope).sort!,
    }
  end
end

module Facet
  module RBAC
    describe GrantResolver do
      # ── Grant parsing ────────────────────────────────────────────────────

      describe Grant do
        it "parses a concrete target with required and optional actions" do
          grant = Grant.from_json(JSON.parse(%({
            "target": "crm.Contact",
            "actions": [
              {"name": "read",  "required": true},
              {"name": "write", "required": false}
            ]
          })))

          grant.domain.should eq("crm")
          grant.path.should eq(["Contact"])
          # `write` is expanded into create + update at parse time.
          grant.actions.map(&.name).should eq(["read", "create", "update"])
          grant.actions.map(&.required).should eq([true, false, false])
        end

        it "expands `write` and applies the required flag to both expansions" do
          grant = Grant.from_json(JSON.parse(%({
            "target": "crm.Comment",
            "actions": [{"name": "write", "required": true}]
          })))

          grant.actions.map(&.name).should eq(["create", "update"])
          grant.actions.map(&.required).should eq([true, true])
        end

        it "defaults `required` to false when absent" do
          grant = Grant.from_json(JSON.parse(%({
            "target": "crm.Contact",
            "actions": [{"name": "read"}]
          })))

          grant.actions.first.required.should be_false
          grant.has_required?.should be_false
        end

        it "deduplicates action names after write expansion" do
          grant = Grant.from_json(JSON.parse(%({
            "target": "crm.Contact",
            "actions": [
              {"name": "create"},
              {"name": "write"}
            ]
          })))

          # `write` expands to {create, update}; `create` is already seen,
          # so the canonical set is {create, update} — no doubled create.
          grant.actions.map(&.name).sort!.should eq(["create", "update"])
        end

        it "accepts a domain wildcard target (crm.*)" do
          grant = Grant.from_json(JSON.parse(%({
            "target": "crm.*",
            "actions": [{"name": "read", "required": true}]
          })))

          grant.domain.should eq("crm")
          grant.path.should eq(["*"])
        end

        it "rejects the global '*.*' wildcard as a grant target" do
          expect_raises(ArgumentError, /concrete domain/) do
            Grant.from_json(JSON.parse(%({
              "target": "*.*",
              "actions": [{"name": "read"}]
            })))
          end
        end

        it "rejects a wildcard that is not the leaf segment" do
          expect_raises(ArgumentError, /wildcard may only appear/) do
            Grant.from_json(JSON.parse(%({
              "target": "crm.*.Comment",
              "actions": [{"name": "read"}]
            })))
          end
        end

        it "rejects an empty actions array" do
          expect_raises(ArgumentError, /must not be empty/) do
            Grant.from_json(JSON.parse(%({
              "target": "crm.Contact",
              "actions": []
            })))
          end
        end

        it "rejects a target without a domain" do
          expect_raises(ArgumentError, /at least domain and doctype/) do
            Grant.from_json(JSON.parse(%({
              "target": "Contact",
              "actions": [{"name": "read"}]
            })))
          end
        end
      end

      # ── role_usable? ──────────────────────────────────────────────────────

      describe ".role_usable?" do
        it "is true when the role covers every required action" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact")])

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is false when the role misses a required action" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read",  "required": true},
                         {"name": "delete", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact")])

          GrantResolver.role_usable?(app, r).should be_false
        end

        it "is false when the role misses the target doctype entirely" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Other")])

          GrantResolver.role_usable?(app, r).should be_false
        end

        it "is true when missing actions are all optional" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read",  "required": true},
                         {"name": "delete", "required": false}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact")])

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is false when ANY of multiple required grants is not covered" do
          # Conjunction across grant entries: both required, role covers
          # only the first.
          app = app_scope(%([
            {"target": "crm.Contact",  "actions": [{"name": "read", "required": true}]},
            {"target": "crm.Pipeline", "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact")])

          GrantResolver.role_usable?(app, r).should be_false
        end

        it "is true when required grants target wildcards the role covers" do
          # Required action on `crm.*` is satisfied by a role permission on
          # any concrete doctype within the crm domain.
          app = app_scope(%([
            {"target": "crm.*",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact")])

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is false when a required wildcard grant has no matching doctype" do
          app = app_scope(%([
            {"target": "crm.*",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "iam.Account")])

          GrantResolver.role_usable?(app, r).should be_false
        end

        it "is true when a required write grant is covered by create+update" do
          app = app_scope(%([
            {"target": "crm.Comment",
             "actions": [{"name": "write", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("create", "crm.Comment"), rbac_perm("update", "crm.Comment")])

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is false when a required write grant lacks update on the role" do
          app = app_scope(%([
            {"target": "crm.Comment",
             "actions": [{"name": "write", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("create", "crm.Comment")])

          GrantResolver.role_usable?(app, r).should be_false
        end

        it "is true when a required action is covered by the role's `*` action" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "delete", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("*", "crm.Contact")])

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is true for an app with no required actions at all" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": false}]}
          ]))
          r = rbac_role([] of Permission)

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is true for an app with no grants" do
          app = app_scope("[]")
          r = rbac_role([] of Permission)

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is false when the only covering line excepts the concrete grant target" do
          app = app_scope(%([
            {"target": "core.SystemSettings",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([Permission.new(action: "read", domain: "*", path: ["*"],
            except: ["core.SystemSettings"])])

          GrantResolver.role_usable?(app, r).should be_false
        end

        it "is true when the except list carves only other doctypes" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([Permission.new(action: "read", domain: "*", path: ["*"],
            except: ["core.SystemSettings", "iam.OIDCProvider"])])

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is false when an except entry prefix-covers a descendant grant target" do
          # except core.DocType carves core.DocType.Comment too — the
          # prefix rule matches enforcement (`matches_except?`).
          app = app_scope(%([
            {"target": "core.DocType.Comment",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([Permission.new(action: "read", domain: "*", path: ["*"],
            except: ["core.DocType"])])

          GrantResolver.role_usable?(app, r).should be_false
        end

        it "is true when the except entry only carves a descendant of the grant" do
          app = app_scope(%([
            {"target": "core.DocType",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([Permission.new(action: "read", domain: "*", path: ["*"],
            except: ["core.DocType.Comment"])])

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "is true for an admin line without carve-outs against a concrete grant" do
          # The admin-like role: *.* with no except reaches every concrete
          # target, so it can always back an application.
          app = app_scope(%([
            {"target": "core.SystemSettings",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("*", "*.*")])

          GrantResolver.role_usable?(app, r).should be_true
        end

        it "keeps the lenient reading for a wildcard grant target" do
          # A `crm.*` grant is satisfiable when at least one doctype in the
          # domain survives the carve-out. (The authoring gate refuses
          # wildcard targets on app grants; the resolver stays tolerant of
          # content that reaches it without the gate.)
          app = app_scope(%([
            {"target": "crm.*",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([Permission.new(action: "read", domain: "*", path: ["*"],
            except: ["crm.Secret"])])

          GrantResolver.role_usable?(app, r).should be_true
        end
      end

      # ── missing_required_actions ─────────────────────────────────────────

      describe ".missing_required_actions" do
        it "is empty when the role covers every required action" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact")])

          GrantResolver.missing_required_actions(app, r).should eq([] of String)
        end

        it "names the missing action and its grant target" do
          app = app_scope(%([
            {"target": "fin.Invoice",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("create", "fin.Invoice")])

          GrantResolver.missing_required_actions(app, r)
            .should eq(["read on fin.Invoice"])
        end

        it "reports both halves of an unmet `write` expansion" do
          # The run-48 fixture: grant `write` (expands to create + update,
          # both required), role line holds only `create`. The role fails
          # `role_usable?` and the diagnostic names exactly what to add.
          app = app_scope(%([
            {"target": "fin.Invoice",
             "actions": [{"name": "write", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("create", "fin.Invoice")])

          GrantResolver.role_usable?(app, r).should be_false
          GrantResolver.missing_required_actions(app, r)
            .should eq(["update on fin.Invoice"])
        end

        it "lists gaps across grant entries without duplicates" do
          app = app_scope(%([
            {"target": "fin.Invoice", "actions": [{"name": "read", "required": true}]},
            {"target": "fin.Payment", "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([] of Permission)

          GrantResolver.missing_required_actions(app, r)
            .should eq(["read on fin.Invoice", "read on fin.Payment"])
        end

        it "is empty for optional-only grants even with no permissions" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": false}]}
          ]))
          r = rbac_role([] of Permission)

          GrantResolver.missing_required_actions(app, r).should eq([] of String)
        end

        it "names a required action whose only covering line carves it out" do
          # The viewer-style line: read on *.* except core.SystemSettings.
          # Enforcement refuses the carved-out doctype outright, so the
          # gate must refuse it too — the app is unusable, not partially
          # usable.
          app = app_scope(%([
            {"target": "core.SystemSettings",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([Permission.new(action: "read", domain: "*", path: ["*"],
            except: ["core.SystemSettings", "iam.OIDCProvider"])])

          GrantResolver.missing_required_actions(app, r)
            .should eq(["read on core.SystemSettings"])
        end
      end

      # ── resolve ──────────────────────────────────────────────────────────

      describe ".resolve" do
        it "emits an entry per covered action when the role covers them" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read",  "required": true},
                         {"name": "delete", "required": false}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact"), rbac_perm("delete", "crm.Contact")])

          scope = GrantResolver.resolve(app, r)
          decoded(scope).should eq([{
            target:  "crm.Contact",
            domain:  "crm",
            path:    ["Contact"],
            actions: ["delete", "read"],
            scopes:  [] of String,
          }])
        end

        it "omits optional actions the role does not cover" do
          # Role covers read but not delete. Read is covered, delete is
          # absent from the entry. The app declared delete as optional,
          # so the role stays usable and the entry omits delete.
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read",  "required": true},
                         {"name": "delete", "required": false}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact")])

          scope = GrantResolver.resolve(app, r)
          decoded(scope).should eq([{
            target:  "crm.Contact",
            domain:  "crm",
            path:    ["Contact"],
            actions: ["read"],
            scopes:  [] of String,
          }])
        end

        it "expands `write` into create+update, each tested against the role" do
          # The role has create but not update. The optional `write` grant
          # contributes `create` to the entry but not `update` — granular,
          # not all-or-nothing per the optional write case.
          app = app_scope(%([
            {"target": "crm.Comment",
             "actions": [{"name": "read",  "required": true},
                         {"name": "write", "required": false}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Comment"), rbac_perm("create", "crm.Comment")])

          scope = GrantResolver.resolve(app, r)
          decoded(scope).should eq([{
            target:  "crm.Comment",
            domain:  "crm",
            path:    ["Comment"],
            actions: ["create", "read"],
            scopes:  [] of String,
          }])
        end

        it "emits one entry per doctype for a wildcard grant intersection" do
          # `crm.*` grant ∩ role permissions on crm.Contact and crm.Company
          # ⇒ two entries, one per concrete doctype the role actually holds.
          app = app_scope(%([
            {"target": "crm.*",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact"), rbac_perm("read", "crm.Company")])

          scope = GrantResolver.resolve(app, r)
          result = decoded(scope).sort_by(&.[:path].join("."))
          result.should eq([
            {target: "crm.*", domain: "crm", path: ["Company"], actions: ["read"], scopes: [] of String},
            {target: "crm.*", domain: "crm", path: ["Contact"], actions: ["read"], scopes: [] of String},
          ])
        end

        it "merges the wildcard and the specific grant on the same doctype (B-23)" do
          # `crm.*` (read) + `crm.Invoice` (read, update), role holds read+update
          # on Invoice and read on Contact: one merged Invoice entry with the
          # action union — never two rows with one target string.
          app = app_scope(%([
            {"target": "crm.*",
             "actions": [{"name": "read", "required": true}]},
            {"target": "crm.Invoice",
             "actions": [{"name": "read", "required": true},
                         {"name": "update", "required": false}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact"),
                         rbac_perm("read", "crm.Invoice"),
                         rbac_perm("update", "crm.Invoice")])

          scope = GrantResolver.resolve(app, r)
          result = decoded(scope).sort_by(&.[:path].join("."))
          result.should eq([
            {target: "crm.*", domain: "crm", path: ["Contact"], actions: ["read"], scopes: [] of String},
            {target: "crm.*", domain: "crm", path: ["Invoice"], actions: ["read", "update"], scopes: [] of String},
          ])
        end

        it "emits nothing for a wildcard grant when the role has no matching doctype" do
          app = app_scope(%([
            {"target": "crm.*",
             "actions": [{"name": "read", "required": false}]}
          ]))
          r = rbac_role([rbac_perm("read", "iam.Account")])

          scope = GrantResolver.resolve(app, r)
          scope.empty?.should be_true
        end

        it "matches a grant on a parent doctype against a role permission on the child" do
          # Grant `crm.Contact` covers a role permission on `crm.Contact.Comment`
          # (mirrors Permission#matches_path? prefix rule, in the grant direction).
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact.Comment")])

          GrantResolver.role_usable?(app, r).should be_true
          scope = GrantResolver.resolve(app, r)
          decoded(scope).should eq([{
            target:  "crm.Contact",
            domain:  "crm",
            path:    ["Contact", "Comment"],
            actions: ["read"],
            scopes:  [] of String,
          }])
        end

        it "preserves the role's scope aliases untouched on the emitted permissions" do
          # Scope is pass-through: a role permission carrying `["mine"]` must
          # surface verbatim on the matching entry's permissions, so the
          # enforcer runs the row-level predicate as today.
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "crm.Contact", scope: ["$mine"])])

          scope = GrantResolver.resolve(app, r)
          entry = scope.entries.first
          entry.permissions.size.should eq(1)
          entry.permissions.first.scope.should eq(["$mine"])
        end

        it "treats the role's `*` action as covering any grant action" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read",   "required": true},
                         {"name": "delete", "required": false},
                         {"name": "promote", "required": false}]}
          ]))
          r = rbac_role([rbac_perm("*", "crm.Contact")])

          GrantResolver.role_usable?(app, r).should be_true
          scope = GrantResolver.resolve(app, r)
          decoded(scope).should eq([{
            target:  "crm.Contact",
            domain:  "crm",
            path:    ["Contact"],
            actions: ["delete", "promote", "read"],
            scopes:  [] of String,
          }])
        end

        it "emits the grant's target coordinates for an admin `*.*` permission" do
          # The admin role reaches every doctype via its own `*.*` permission;
          # the grant is strictly a ceiling. The entry collapses to the
          # grant's de-wildcarded target (`crm.Contact`), NOT a wildcard `*`
          # entry — the grant is the ceiling, not the reach.
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read",   "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "*.*")])

          # Permission path checks (debug assertion):
          r.permissions.first.domain.should eq("*")
          r.permissions.first.path.should eq(["*"])
          # Grant is a concrete crm.Contact grant.
          app.grants.first.covers?("*", ["*"]).should be_true
          GrantResolver.role_usable?(app, r).should be_true
          scope = GrantResolver.resolve(app, r)
          decoded(scope).should eq([{
            target:  "crm.Contact",
            domain:  "crm",
            path:    ["Contact"],
            actions: ["read"],
            scopes:  [] of String,
          }])
        end

        it "works with a `domain.*` grant and an admin `*.*` permission" do
          # The grant asks for every doctype in crm; the admin role covers
          # every doctype in every domain. The grant cannot enumerate the
          # concrete crm doctypes (it has no role-permission match to derive
          # them from), so the entry collapses to the grant's wildcard target
          # — but the resolver only knows the role's `*.*` permission, so
          # the entry coordinates are the grant's domain + a wildcard leaf.
          # Test the documented behaviour: the scope is non-empty AND the
          # entry covers `crm` (and only `crm`, since the grant names crm).
          app = app_scope(%([
            {"target": "crm.*",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "*.*")])

          GrantResolver.role_usable?(app, r).should be_true
          scope = GrantResolver.resolve(app, r)
          scope.empty?.should be_false
          entry = scope.entries.first
          entry.domain.should eq("crm")
          entry.path.should eq(["*"])
          entry.actions.should eq(Set{"read"})
        end

        it "combines multiple matching role permissions into one entry (intra-role OR)" do
          # Two role permissions on the same (domain, path) — one grants read,
          # one grants delete. The entry's permissions array carries both.
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read",   "required": true},
                         {"name": "delete", "required": false}]}
          ]))
          r = rbac_role([
            rbac_perm("read", "crm.Contact", scope: ["$mine"]),
            rbac_perm("delete", "crm.Contact", scope: ["$global"]),
          ])

          scope = GrantResolver.resolve(app, r)
          entry = scope.entries.first
          entry.actions.should eq(Set{"read", "delete"})
          entry.permissions.size.should eq(2)
          entry.permissions.flat_map(&.scope).sort!.should eq(["$global", "$mine"])
        end

        it "does not emit an entry when the role covers the doctype but no granted actions" do
          # Grant asks for read+delete, role permits only update on the
          # doctype — neither action is covered ⇒ entry absent.
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read",   "required": false},
                         {"name": "delete", "required": false}]}
          ]))
          r = rbac_role([rbac_perm("update", "crm.Contact")])

          scope = GrantResolver.resolve(app, r)
          scope.empty?.should be_true
        end

        it "rejects a role with zero overlap with the app grant set" do
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": true}]}
          ]))
          r = rbac_role([rbac_perm("read", "iam.Account")])

          GrantResolver.role_usable?(app, r).should be_false
          GrantResolver.resolve(app, r).empty?.should be_true
        end

        it "treats an all-optional app whose grants are not matched as usable but empty-scoped" do
          # The empty-effective-scope rule is NOT a usability gate. A role is
          # rejected only when a required action is missing. An all-optional
          # app whose grants the role covers none of stays usable; the future
          # enforcer denies every operation under the token because the scope
          # is empty.
          app = app_scope(%([
            {"target": "crm.Contact",
             "actions": [{"name": "read", "required": false}]}
          ]))
          r = rbac_role([] of Permission)

          GrantResolver.role_usable?(app, r).should be_true
          GrantResolver.resolve(app, r).empty?.should be_true
        end

        it "round-trips an AppScope built from an app.App projection content" do
          # Mirrors the app grant shape: write expanded at parse time.
          content = JSON.parse(%({
            "slug": "crm-portal",
            "client_id": "01H8XGJTB8K7P3QR9V2Z6Y4M5N",
            "grants": [
              {"target": "crm.*", "actions": [{"name": "read", "required": true}]},
              {"target": "crm.Contact", "actions": [
                {"name": "read",  "required": false},
                {"name": "write", "required": false}
              ]}
            ]
          }))
          scope = AppScope.from_content("01H8XGJT...", content)

          scope.app_id.should eq("01H8XGJT...")
          scope.grants.map(&.target).should eq(["crm.*", "crm.Contact"])
          # Second grant: write expanded into {create, update}.
          scope.grants[1].actions.map(&.name).should eq(["read", "create", "update"])
          scope.grants[1].actions.all? { |a| !a.required }.should be_true
        end
      end
    end
  end
end

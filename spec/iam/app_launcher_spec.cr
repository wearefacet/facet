# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/app_launcher"
require "../support/app_helper"
require "../support/iam_helper"
require "../support/oauth_helper"

# `IAM::AppLauncher` — the dashboard launcher service.
#
# Every active app is listed — client type does not filter, so a
# `confidential` app gets a card like a `public` app. `usable` on each
# entry reports whether the active role satisfies every required grant
# action (`GrantResolver.role_usable?`). These specs cover the usable
# flag, the still-listed-but-not-usable case, the hard exclusions (status,
# no_launcher) and the role-not-found fail-closed case.
#
# The fixtures reuse the OAuth spec helpers (`create_test_app`,
# `create_test_role`) so the `app.App` create hook runs and `client_id` is
# materialised the same way production paths materialise it.

# Creates an `iam.Roles` row that grants `read` on `crm.*` — enough to
# satisfy a grant whose only required action is `read` on `crm.Contact`.
def crm_reader_role(db) : String
  create_test_role(db, "crm_reader", [oauth_perm("read", "crm.*")])
end

describe Facet::IAM::AppLauncher do
  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
      seed_test_roles(db)
    end
  end

  it "lists an active app whose grants the role satisfies as usable" do
    with_db do |db|
      role_id = crm_reader_role(db)
      create_test_app(db, "portal",
        display_name: "CRM Portal",
        description: "External CRM frontend.",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, role_id)
      apps.size.should eq(1)
      a = apps.first
      a.slug.should start_with("portal-")
      a.display_name.should eq("CRM Portal")
      a.description.should eq("External CRM frontend.")
      a.usable.should be_true
    end
  end

  it "lists an app the read-only viewer role cannot open, flagged not usable" do
    with_db do |db|
      # `seed_test_roles` seeds `viewer` — read-only on `*.*`. The app
      # requires `create`, so `role_usable?` fails, but the app stays
      # listed so the account can see it and ask for access.
      create_test_app(db, "portal",
        display_name: "Write Portal",
        grants: [oauth_grant("crm.Contact", [oauth_action("create", required: true)])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, "iam.Roles.viewer")
      apps.size.should eq(1)
      apps.first.usable.should be_false
    end
  end

  it "drops optional actions the role lacks when computing usable" do
    with_db do |db|
      role_id = crm_reader_role(db)
      # `read` required (role has it), `write` optional (role lacks it).
      # The app is still usable — optional actions never reject.
      create_test_app(db, "portal",
        grants: [oauth_grant("crm.Contact", [
          oauth_action("read", required: true),
          oauth_action("write", required: false),
        ])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, role_id)
      apps.size.should eq(1)
      apps.first.usable.should be_true
    end
  end

  it "excludes a disabled app even when the role satisfies the grants" do
    with_db do |db|
      role_id = crm_reader_role(db)
      create_test_app(db, "portal",
        status: "disabled",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, role_id)
      apps.should be_empty
    end
  end

  it "excludes a draft app even when the role satisfies the grants" do
    with_db do |db|
      role_id = crm_reader_role(db)
      create_test_app(db, "portal",
        status: "draft",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, role_id)
      apps.should be_empty
    end
  end

  it "excludes an app marked no_launcher even when the role satisfies the grants" do
    with_db do |db|
      role_id = crm_reader_role(db)
      create_test_app(db, "portal",
        no_launcher: true,
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, role_id)
      apps.should be_empty
    end
  end

  it "lists a confidential app — client type does not filter the launcher" do
    with_db do |db|
      role_id = crm_reader_role(db)
      create_test_app(db, "portal",
        client_type: "confidential",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, role_id)
      apps.size.should eq(1)
      apps.first.usable.should be_true
    end
  end

  it "returns an empty list when the role has no projection row" do
    with_db do |db|
      create_test_app(db, "portal",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, "iam.Roles.nonexistent")
      apps.should be_empty
    end
  end

  it "returns the public summary fields" do
    with_db do |db|
      role_id = crm_reader_role(db)
      create_test_app(db, "portal",
        redirect_uris: ["https://portal.example.com/cb"],
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])],
      )

      apps = Facet::IAM::AppLauncher.launcher_apps(db, role_id)
      apps.size.should eq(1)
      a = apps.first
      a.id.should_not be_empty
      a.slug.should start_with("portal-")
      a.display_name.should eq("Test App")
      a.description.should eq("An app for tests.")
      # `AppSummary` is a `record` with exactly five fields (id, slug,
      # display_name, description, usable). The type system prevents secret
      # fields (client_id, grants, redirect_uris) from leaking into the
      # launcher response — no runtime assertion needed.
    end
  end
end

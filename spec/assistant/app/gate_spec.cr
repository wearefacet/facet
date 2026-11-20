# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../support/app_assistant_helper"
require "../../../src/assistant/app/gate"

describe Facet::Assistant::App::Gate do
  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "allows an app-scoped caller whose app is enabled and whose role carries assistant_access" do
    with_db do |db|
      role_id = "appas_on_#{unique_suffix}"
      account_id = appas_create_role_and_account(db, role_id, true)
      app = appas_create_app(db, "appas-on-#{unique_suffix}", true)
      ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

      Facet::Database.with_db(:read_only) do |conn|
        Facet::Assistant::App::Gate.allowed?(conn, ctx, app.id).should be_true
      end
    end
  end

  it "refuses an app id that names no live projection" do
    with_db do |db|
      role_id = "appas_ghost_#{unique_suffix}"
      account_id = appas_create_role_and_account(db, role_id, true)
      ctx = appas_app_scoped_context(db, account_id, role_id, "01JGHOSTAPP")

      Facet::Database.with_db(:read_only) do |conn|
        Facet::Assistant::App::Gate.allowed?(conn, ctx, "01JGHOSTAPP").should be_false
      end
    end
  end

  it "refuses when the app has the assistant disabled" do
    with_db do |db|
      role_id = "appas_off_#{unique_suffix}"
      account_id = appas_create_role_and_account(db, role_id, true)
      app = appas_create_app(db, "appas-off-#{unique_suffix}", false)
      ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

      Facet::Database.with_db(:read_only) do |conn|
        Facet::Assistant::App::Gate.allowed?(conn, ctx, app.id).should be_false
      end
    end
  end

  it "refuses a main-app session user whose token carries no app id" do
    with_db do |db|
      role_id = "appas_sess_#{unique_suffix}"
      account_id = appas_create_role_and_account(db, role_id, true)
      app = appas_create_app(db, "appas-sess-#{unique_suffix}", true)
      ctx = appas_session_context(db, account_id, role_id)

      Facet::Database.with_db(:read_only) do |conn|
        Facet::Assistant::App::Gate.allowed?(conn, ctx, app.id).should be_false
      end
    end
  end

  it "refuses an app token that names a different app" do
    with_db do |db|
      role_id = "appas_swap_#{unique_suffix}"
      account_id = appas_create_role_and_account(db, role_id, true)
      app = appas_create_app(db, "appas-mine-#{unique_suffix}", true)
      other = appas_create_app(db, "appas-other-#{unique_suffix}", true)
      ctx = appas_app_scoped_context(db, account_id, role_id, other.id)

      Facet::Database.with_db(:read_only) do |conn|
        Facet::Assistant::App::Gate.allowed?(conn, ctx, app.id).should be_false
      end
    end
  end

  it "refuses when the active role lacks assistant_access" do
    with_db do |db|
      role_id = "appas_norole_#{unique_suffix}"
      account_id = appas_create_role_and_account(db, role_id, false)
      app = appas_create_app(db, "appas-norole-#{unique_suffix}", true)
      ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

      Facet::Database.with_db(:read_only) do |conn|
        Facet::Assistant::App::Gate.allowed?(conn, ctx, app.id).should be_false
      end
    end
  end

  it "reads the flag live: a disable applies on the next check" do
    with_db do |db|
      role_id = "appas_live_#{unique_suffix}"
      account_id = appas_create_role_and_account(db, role_id, true)
      app = appas_create_app(db, "appas-live-#{unique_suffix}", true)
      ctx = appas_app_scoped_context(db, account_id, role_id, app.id)

      Facet::Database.with_db(:read_only) do |conn|
        Facet::Assistant::App::Gate.allowed?(conn, ctx, app.id).should be_true
      end

      upd = Facet::Document::Update.call(
        db, "app", "App", app.id, %({"assistant_enabled": false}),
        Facet::RBAC::AuthContext.system,
      )
      upd.should be_a(Facet::Document::Update::Result)

      Facet::Database.with_db(:read_only) do |conn|
        Facet::Assistant::App::Gate.allowed?(conn, ctx, app.id).should be_false
      end
    end
  end
end

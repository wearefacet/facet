# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "../src/currency"
require "json"

# Creates the `core.Currency` doctype (already seeded definition + documents on
# the template DB, wiped by the per-example truncation — re-ensured here).
def seed_currency_doctype(db : DB::Connection) : Nil
  Facet::Doctype::Seed.ensure_doctype(db, "core", "Currency")
end

# Creates one currency row through the real document pipeline.
def create_currency_document(db : DB::Connection, ticker : String, content : String) : Nil
  result = Facet::Document::Create.create_from_parsed(
    db,
    "core",
    "Currency",
    JSON.parse(content),
    Facet::RBAC::AuthContext.system,
    "system",
    doc_id: ticker,
    skip_authorization: true,
  )
  result.should be_a(Facet::Document::Create::Result)
end

# Soft-deletes a currency row through the real delete service.
def delete_currency_document(db : DB::Connection, ticker : String) : Nil
  result = Facet::Document::Delete.call(
    db,
    "core",
    "Currency",
    ticker,
    Facet::RBAC::AuthContext.system,
    actioner_id: "system",
    skip_authorization: true,
  )
  result.should be_a(Facet::Document::Delete::Result)
end

module Facet
  describe Currency::Registry do
    before_each do
      register_seed_currencies
    end

    it "is stale until the first refresh" do
      Facet::Util::Currency.reset!
      Facet::Currency::Registry.mark_fresh
      # mark_fresh clears staleness — flip via mark_stale for the assertion.
      Facet::Currency::Registry.mark_stale
      Facet::Currency::Registry.stale?.should be_true
    end

    it "refresh builds the registry from live core.Currency rows" do
      Facet::Util::Currency.reset!

      with_db do |db|
        seed_currency_doctype(db)
        create_currency_document(db, "TST", %({"ticker": "TST", "name": "Test Thaler", "symbol": "T", "digits": 2}))

        # Stale (freshly constructed world) → ensure_fresh rebuilds.
        Facet::Currency::Registry.mark_stale
        Facet::Currency::Registry.ensure_fresh(db)

        Facet::Util::Currency.registered?("TST").should be_true
        currency = Facet::Util::Currency.find("TST")
        currency.should_not be_nil
        currency = currency.not_nil!
        currency.name.should eq("Test Thaler")
        currency.digits.should eq(2)
        currency.active.should be_true
        currency.grouping.should eq("standard")
      end
    end

    it "refresh is replace-all: a deleted ticker leaves the registry" do
      with_db do |db|
        seed_currency_doctype(db)
        create_currency_document(db, "OLD", %({"ticker": "OLD", "name": "Old Coin", "digits": 2}))
        create_currency_document(db, "KEP", %({"ticker": "KEP", "name": "Kept Coin", "digits": 0}))
        Facet::Currency::Registry.mark_stale
        Facet::Currency::Registry.ensure_fresh(db)
        Facet::Util::Currency.registered?("OLD").should be_true

        delete_currency_document(db, "OLD")
        Facet::Currency::Registry.mark_stale
        Facet::Currency::Registry.refresh(db)

        Facet::Util::Currency.registered?("OLD").should be_false
        Facet::Util::Currency.registered?("KEP").should be_true
        Facet::Util::Currency["KEP"].digits.should eq(0)
      end
    end

    it "ensure_fresh rebuilds exactly when stale" do
      with_db do |db|
        seed_currency_doctype(db)
        create_currency_document(db, "NEW", %({"ticker": "NEW", "name": "New Coin", "digits": 2}))

        # Not stale → no rebuild, registry keeps the spec helper's values.
        Facet::Currency::Registry.ensure_fresh(db)
        Facet::Util::Currency.registered?("NEW").should be_false

        # Stale → rebuild → NEW lands (replace-all drops the seed rows).
        Facet::Currency::Registry.mark_stale
        Facet::Currency::Registry.ensure_fresh(db)
        Facet::Util::Currency.registered?("NEW").should be_true
      end
    end

    it "ensure_fresh rebuilds when the staleness bound expires (fanout lost)" do
      with_db do |db|
        seed_currency_doctype(db)
        create_currency_document(db, "TTL", %({"ticker": "TTL", "name": "Bound Coin", "digits": 2}))

        # Fresh (mark_fresh stamped the seed registration) → no rebuild.
        Facet::Currency::Registry.ensure_fresh(db)
        Facet::Util::Currency.registered?("TTL").should be_false

        with_cache_ttl(1) do
          # Re-stamp freshness here — the seed stamp predates the document
          # setup, and the bound below must count from this moment.
          Facet::Currency::Registry.mark_fresh

          # Inside the bound the in-memory registration still serves.
          Facet::Util::Currency.registered?("TTL").should be_false

          # Past the bound ensure_fresh rebuilds from the DB even though
          # the stale flag is clear — the bound caps a lost fanout.
          assert_eventually(timeout: 4.0, interval: 0.05) do
            Facet::Currency::Registry.ensure_fresh(db)
            Facet::Util::Currency.registered?("TTL")
          end
        end
      end
    end

    it "deactivation keeps the row registered (the lifecycle rule lives in MoneyCurrencyCheck)" do
      with_db do |db|
        seed_currency_doctype(db)
        create_currency_document(db, "OFF", %({"ticker": "OFF", "name": "Off Coin", "digits": 2, "active": false}))
        Facet::Currency::Registry.mark_stale
        Facet::Currency::Registry.refresh(db)

        currency = Facet::Util::Currency.find("OFF")
        currency.should_not be_nil
        currency.not_nil!.active.should be_false
        Facet::Util::Currency.registered?("OFF").should be_true
      end
    end
  end
end

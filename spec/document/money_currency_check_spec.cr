# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "../../src/document/money_currency_check"
require "json"

# Creates a doctype with the caller's fields. The name is unique per
# example; the domain is a throwaway per-example domain.
private def create_money_doctype(db : DB::Connection, domain : String, doctype : String, fields : String) : Nil
  ensure_domain(db, domain)
  schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": #{fields}})
  Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
    .should be_a(Facet::Document::Create::Result)
end

private def create_document(db : DB::Connection, domain : String, doctype : String, body : String) : Facet::Document::Create::Result | Facet::ServiceError
  Facet::Document::Create.call(db, domain, doctype, body, Facet::RBAC::AuthContext.system)
end

# Stores one document through the create service and returns its id.
private def store_money_document(db : DB::Connection, domain : String, doctype : String, body : String) : String
  result = create_document(db, domain, doctype, body)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection.id
end

private def update_document(db : DB::Connection, domain : String, doctype : String, doc_id : String, body : String) : Facet::Document::Update::Result | Facet::ServiceError
  Facet::Document::Update.call(db, domain, doctype, doc_id, body, Facet::RBAC::AuthContext.system)
end

# Asserts the result is a 422 whose first structured detail names the
# code. Returns the detail for further assertions.
private def first_detail(result : Facet::Document::Create::Result | Facet::Document::Update::Result | Facet::ServiceError, code : String) : Facet::ValidationError
  result.should be_a(Facet::ServiceError)
  err = result.as(Facet::ServiceError)
  err.status.should eq(422)
  detail = err.details.try(&.first?)
  detail.should_not be_nil
  detail = detail.not_nil!
  detail.code.should eq(code)
  detail
end

# Lifecycle rule for money fields (`Document::MoneyCurrencyCheck`), covered
# through the real create/update services so the wiring is what is under
# test. The examples write USD (active in the seed set) and register their
# own inactive tickers (`OLD`, `GON`) on top.
describe Facet::Document::MoneyCurrencyCheck do
  before_each do
    register_seed_currencies
    Facet::Util::Currency.register({
      "OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false),
      "GON" => Facet::Util::Currency.new(ticker: "GON", name: "Gone Coin", digits: 0, active: false),
    })
  end

  describe "create path" do
    it "rejects a money value on an inactive currency with inactive_currency" do
      with_temp_doctype("mccreate", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"title": {"type": "string"}, "price": {"type": "money"}}))

        result = create_document(db, domain, dt,
          %({"title": "deal", "price": #{money_json("10.00", "OLD")}}))

        detail = first_detail(result, "inactive_currency")
        detail.field.should eq("price.currency")
        detail.message.should contain("OLD")
      end
    end

    it "keeps the unknown-ticker failure in MoneyType#validate (schema error)" do
      with_temp_doctype("mccreateu", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt, %({"price": {"type": "money"}}))

        result = create_document(db, domain, dt,
          %({"price": #{money_json("10.00", "XYZ")}}))

        detail = first_detail(result, "schema")
        detail.field.should eq("price.currency")
      end
    end

    it "accepts an active currency" do
      with_temp_doctype("mccreatea", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt, %({"price": {"type": "money"}}))

        result = create_document(db, domain, dt,
          %({"price": #{money_json("10.00", "USD")}}))

        result.should be_a(Facet::Document::Create::Result)
      end
    end

    it "passes when the money field is absent" do
      with_temp_doctype("mccreaten", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt, %({"price": {"type": "money"}}))

        result = create_document(db, domain, dt, %({}))

        result.should be_a(Facet::Document::Create::Result)
      end
    end

    it "rejects an inactive ticker nested in array items" do
      with_temp_doctype("mccarr", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"prices": {"type": "array", "items": {"type": "money"}}}))

        result = create_document(db, domain, dt, %({
          "prices": [#{money_json("1.00", "USD")}, #{money_json("2.00", "OLD")}]
        }))

        detail = first_detail(result, "inactive_currency")
        detail.field.should eq("prices.1.currency")
      end
    end

    it "rejects an inactive ticker nested in object properties" do
      with_temp_doctype("mccobj", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"meta": {"type": "object", "properties": {"total": {"type": "money"}}}}))

        result = create_document(db, domain, dt, %({
          "meta": {"total": #{money_json("5.00", "GON")}}
        }))

        detail = first_detail(result, "inactive_currency")
        detail.field.should eq("meta.total.currency")
      end
    end

    it "rejects an inactive ticker nested in dictionary values" do
      with_temp_doctype("mccdict", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"rates": {"type": "dictionary", "values": {"type": "money"}}}))

        result = create_document(db, domain, dt, %({
          "rates": {"eu": #{money_json("7.00", "OLD")}}
        }))

        detail = first_detail(result, "inactive_currency")
        detail.field.should eq("rates.eu.currency")
      end
    end

    it "rejects an inactive ticker nested through array → object → money" do
      with_temp_doctype("mccdeep", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"lines": {"type": "array", "items": {"type": "object", "properties": {"amount": {"type": "money"}}}}}))

        result = create_document(db, domain, dt, %({
          "lines": [{"amount": #{money_json("3.00", "OLD")}}]
        }))

        detail = first_detail(result, "inactive_currency")
        detail.field.should eq("lines.0.amount.currency")
      end
    end
  end

  describe "update path" do
    it "passes when the patch re-saves the same (now inactive) ticker" do
      with_temp_doctype("mcusame", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"price": {"type": "money"}, "label": {"type": "string"}}))

        # OLD starts active so the stored document may hold it, then turns
        # inactive — the real-world deactivation sequence.
        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2)})
        doc_id = store_money_document(db, domain, dt, %({"price": #{money_json("10.00", "OLD")}}))
        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false)})

        result = update_document(db, domain, dt, doc_id, %({"price": #{money_json("20.00", "OLD")}}))

        result.should be_a(Facet::Document::Update::Result)
      end
    end

    it "passes when the patch touches an unrelated field while money holds an inactive ticker" do
      with_temp_doctype("mcuother", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"price": {"type": "money"}, "label": {"type": "string"}}))

        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2)})
        doc_id = store_money_document(db, domain, dt, %({"price": #{money_json("10.00", "OLD")}}))
        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false)})

        result = update_document(db, domain, dt, doc_id, %({"label": "fresh"}))

        result.should be_a(Facet::Document::Update::Result)
      end
    end

    it "passes when a value-only change keeps the same inactive ticker" do
      with_temp_doctype("mcuval", "Deal") do |db, domain, dt|
        # The field-level `currency` gives the normalize step a default to
        # backfill into a partial money patch.
        create_money_doctype(db, domain, dt,
          %({"price": {"type": "money", "currency": "OLD"}}))

        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2)})
        doc_id = store_money_document(db, domain, dt, %({"price": {"value": "10.00"}}))
        Facet::Util::Currency.register({"OLD" => Facet::Util::Currency.new(ticker: "OLD", name: "Old Coin", digits: 2, active: false)})

        # A partial money object merges over the stored one: the currency
        # member carries over, so the ticker stays the same.
        result = update_document(db, domain, dt, doc_id, %({"price": {"value": "99.99"}}))

        result.should be_a(Facet::Document::Update::Result)
      end
    end

    it "rejects switching a money path to an inactive ticker" do
      with_temp_doctype("mcuswitch", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt, %({"price": {"type": "money"}}))

        doc_id = store_money_document(db, domain, dt, %({"price": #{money_json("10.00", "EUR")}}))

        result = update_document(db, domain, dt, doc_id, %({"price": #{money_json("11.00", "OLD")}}))

        detail = first_detail(result, "inactive_currency")
        detail.field.should eq("price.currency")
      end
    end

    it "passes switching a money path to an active ticker" do
      with_temp_doctype("mcuswact", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt, %({"price": {"type": "money"}}))

        doc_id = store_money_document(db, domain, dt, %({"price": #{money_json("10.00", "EUR")}}))

        result = update_document(db, domain, dt, doc_id, %({"price": #{money_json("11.00", "USD")}}))

        result.should be_a(Facet::Document::Update::Result)
      end
    end

    it "rejects adding money (old path absent) on an inactive ticker" do
      with_temp_doctype("mcuadd", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"price": {"type": "money"}, "label": {"type": "string"}}))

        doc_id = store_money_document(db, domain, dt, %({"label": "no money yet"}))

        result = update_document(db, domain, dt, doc_id, %({"price": #{money_json("5.00", "OLD")}}))

        detail = first_detail(result, "inactive_currency")
        detail.field.should eq("price.currency")
      end
    end

    it "keeps the unknown-ticker failure on the update path in the schema error" do
      with_temp_doctype("mcuunk", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt, %({"price": {"type": "money"}}))

        doc_id = store_money_document(db, domain, dt, %({"price": #{money_json("10.00", "EUR")}}))

        result = update_document(db, domain, dt, doc_id, %({"price": #{money_json("11.00", "XYZ")}}))

        detail = first_detail(result, "schema")
        detail.field.should eq("price.currency")
      end
    end

    it "rejects a changed inactive ticker nested in a patched array" do
      with_temp_doctype("mcuarr", "Deal") do |db, domain, dt|
        create_money_doctype(db, domain, dt,
          %({"prices": {"type": "array", "items": {"type": "money"}}}))

        doc_id = store_money_document(db, domain, dt, %({"prices": [#{money_json("1.00", "USD")}]}))

        # Arrays replace as a whole, so the patch carries both elements.
        result = update_document(db, domain, dt, doc_id, %({
          "prices": [#{money_json("1.00", "USD")}, #{money_json("2.00", "GON")}]
        }))

        detail = first_detail(result, "inactive_currency")
        detail.field.should eq("prices.1.currency")
      end
    end
  end

  describe "import mode" do
    it "skips the lifecycle rule for the import path" do
      definition = Facet::Doctype::DoctypeDefinition.from_json(%({
        "doctype": "Deal",
        "domain": "spec",
        "schema_version": 1,
        "fields": {"price": {"type": "money"}}
      }))
      document = JSON.parse(%({"price": #{money_json("10.00", "OLD")}}))

      Facet::Document::MoneyCurrencyCheck.check_create(definition, document, Facet::Document::MoneyCurrencyCheck::Mode::Import)
        .should be_empty
      Facet::Document::MoneyCurrencyCheck.check_update(definition, document, JSON.parse(%({})), Facet::Document::MoneyCurrencyCheck::Mode::Import)
        .should be_empty
    end

    it "reports the inactive case in write mode" do
      definition = Facet::Doctype::DoctypeDefinition.from_json(%({
        "doctype": "Deal",
        "domain": "spec",
        "schema_version": 1,
        "fields": {"price": {"type": "money"}}
      }))
      document = JSON.parse(%({"price": #{money_json("10.00", "OLD")}}))

      errors = Facet::Document::MoneyCurrencyCheck.check_create(definition, document)

      errors.size.should eq(1)
      errors[0].code.should eq("inactive_currency")
      errors[0].field.should eq("price.currency")
    end

    it "is silent when the merged ticker equals the stored one" do
      definition = Facet::Doctype::DoctypeDefinition.from_json(%({
        "doctype": "Deal",
        "domain": "spec",
        "schema_version": 1,
        "fields": {"price": {"type": "money"}}
      }))
      old = JSON.parse(%({"price": #{money_json("10.00", "OLD")}}))
      merged = JSON.parse(%({"price": #{money_json("20.00", "OLD")}}))

      Facet::Document::MoneyCurrencyCheck.check_update(definition, merged, old)
        .should be_empty
    end
  end
end

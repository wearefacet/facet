# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/doctype"

# ── Helpers ─────────────────────────────────────────────────────────────

def definition_with_secret(field_json : String) : Array(Facet::ValidationError)
  json = %({
    "doctype": "Vault",
    "domain": "secretpage",
    "search": "{{ name }}",
    "fields": {
      "name": { "type": "string" },
      "cred": #{field_json}
    }
  })
  Facet::Doctype::Validation.validate(Facet::Doctype::DoctypeDefinition.from_json(json))
end

def validate_fields(fields_json : String) : Array(Facet::ValidationError)
  json = %({
    "doctype": "Vault",
    "domain": "secretpage",
    "search": "{{ display_name }}",
    "fields": #{fields_json}
  })
  Facet::Doctype::Validation.validate(Facet::Doctype::DoctypeDefinition.from_json(json))
end

module Facet::Doctype
  describe SecretType do
    # ── Definition-time rules ────────────────────────────────────────

    describe "validate_definition" do
      it "accepts a hash-mode secret" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash" }))
        errors.should be_empty
      end

      it "accepts a sealed-mode secret" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "sealed" }))
        errors.should be_empty
      end

      it "accepts a token-mode secret with ttl_seconds" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "token", "ttl_seconds": 86400 }))
        errors.should be_empty
      end

      it "accepts min/max/pattern — they constrain the plaintext, not the handle" do
        errors = definition_with_secret(
          %({ "type": "secret", "mode": "hash", "min": 8, "max": 64, "pattern": "^[a-z]+$" })
        )
        errors.should be_empty
      end

      it "rejects a missing mode" do
        errors = definition_with_secret(%({ "type": "secret" }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("mode") }.should be_true
      end

      it "rejects a bogus mode" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "bcrypt" }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("unknown secret mode") }.should be_true
      end

      it "rejects unique" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash", "unique": true }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("unique") }.should be_true
      end

      it "rejects filters" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash", "filters": ["equality"] }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("filters") }.should be_true
      end

      it "rejects compute" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash", "compute": "return 1" }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("compute") }.should be_true
      end

      it "rejects compute_when" do
        errors = definition_with_secret(
          %({ "type": "secret", "mode": "hash", "compute_when": ["name"] })
        )
        errors.any? { |e| e.field == "cred" && e.message.includes?("compute") }.should be_true
      end

      it "rejects replicate" do
        errors = definition_with_secret(
          %({ "type": "secret", "mode": "hash", "replicate": { "via": "name", "field": "name" } })
        )
        errors.any? { |e| e.field == "cred" && e.message.includes?("replicate") }.should be_true
      end

      it "rejects read_only" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash", "read_only": true }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("read_only") }.should be_true
      end

      it "rejects write_only" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash", "write_only": true }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("write_only") }.should be_true
      end

      it "rejects default" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash", "default": "hunter2" }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("default") }.should be_true
      end

      it "rejects collection" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash", "collection": true }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("collection") }.should be_true
      end

      it "rejects items on the secret leaf itself" do
        errors = definition_with_secret(
          %({ "type": "secret", "mode": "hash", "items": { "type": "string" } })
        )
        errors.any? { |e| e.field == "cred" && e.message.includes?("items") }.should be_true
      end

      it "rejects properties on the secret leaf itself" do
        errors = definition_with_secret(
          %({ "type": "secret", "mode": "hash", "properties": { "a": { "type": "string" } } })
        )
        errors.any? { |e| e.field == "cred" && e.message.includes?("properties") }.should be_true
      end

      it "rejects a token secret without ttl_seconds" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "token" }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("ttl_seconds") }.should be_true
      end

      it "rejects a token secret with a non-positive ttl_seconds" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "token", "ttl_seconds": 0 }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("ttl_seconds") }.should be_true
      end

      it "rejects ttl_seconds on a hash secret" do
        errors = definition_with_secret(%({ "type": "secret", "mode": "hash", "ttl_seconds": 60 }))
        errors.any? { |e| e.field == "cred" && e.message.includes?("ttl_seconds") }.should be_true
      end
    end

    # ── Whole-definition placement rules ──────────────────────────────

    describe "placement (Doctype::Validation)" do
      it "accepts a secret inside an object property" do
        errors = validate_fields(%({
          "name": { "type": "string" },
          "credentials": {
            "type": "object",
            "properties": {
              "token": { "type": "secret", "mode": "token", "ttl_seconds": 3600 }
            }
          }
        }))
        errors.should be_empty
      end

      it "rejects a secret inside an array" do
        errors = validate_fields(%({
          "name": { "type": "string" },
          "creds": {
            "type": "array",
            "items": { "type": "secret", "mode": "hash" }
          }
        }))
        errors.any? { |e| e.message.includes?("not allowed inside arrays") }.should be_true
      end

      it "rejects a secret inside a dictionary" do
        errors = validate_fields(%({
          "name": { "type": "string" },
          "creds": {
            "type": "dictionary",
            "values": { "type": "secret", "mode": "hash" }
          }
        }))
        errors.any? { |e| e.message.includes?("not allowed inside dictionaries") }.should be_true
      end

      it "rejects a secret field used in a search template" do
        json = %({
          "doctype": "Vault",
          "domain": "secretpage",
          "search": "{{ name }} {{ cred }}",
          "fields": {
            "name": { "type": "string" },
            "cred": { "type": "secret", "mode": "hash" }
          }
        })
        errors = Validation.validate(DoctypeDefinition.from_json(json))
        errors.any?(&.message.includes?("search template must not reference the secret field 'cred'")).should be_true
      end

      it "rejects a secret object property referenced by a search template root" do
        json = %({
          "doctype": "Vault",
          "domain": "secretpage",
          "search": "{{ credentials.token }}",
          "fields": {
            "credentials": {
              "type": "object",
              "properties": {
                "token": { "type": "secret", "mode": "token", "ttl_seconds": 3600 }
              }
            }
          }
        })
        errors = Validation.validate(DoctypeDefinition.from_json(json))
        errors.any? { |e| e.message.includes?("search template must not reference the secret field 'credentials'") }.should be_true
      end

      it "rejects a secret field referenced by display_name" do
        json = %({
          "doctype": "Vault",
          "domain": "secretpage",
          "display_name": "{{ name }} — {{ cred }}",
          "fields": {
            "name": { "type": "string" },
            "cred": { "type": "secret", "mode": "hash" }
          }
        })
        errors = Validation.validate(DoctypeDefinition.from_json(json))
        errors.any? { |e| e.message.includes?("display_name template must not reference the secret field 'cred'") }.should be_true
      end

      it "rejects a secret-typed action argument" do
        json = %({
          "doctype": "Vault",
          "domain": "secretpage",
          "fields": {
            "name": { "type": "string" },
            "cred": { "type": "secret", "mode": "hash" }
          },
          "actions": {
            "rotate": { "args": { "value": { "type": "secret" } } }
          }
        })
        errors = Validation.validate(DoctypeDefinition.from_json(json))
        errors.any? { |e| e.field == "rotate.value" && e.message.includes?("action argument") }.should be_true
      end
    end

    # ── Document-value shapes ─────────────────────────────────────────

    describe "validate (document values)" do
      type = SecretType.new
      defn = FieldDefinition.new(type: type, mode: "sealed")
      errors = [] of ValidationError

      it "accepts a stage handle" do
        handle = "sh_" + Util::ScriptHelpers.ulid
        errors.clear
        type.validate(JSON.parse(handle.to_json), defn, "cred", errors)
        errors.should be_empty
      end

      it "accepts a marker object" do
        marker = %({"mode": "sealed", "version": 2, "set_at": "2026-09-06T10:00:00Z"})
        errors.clear
        type.validate(JSON.parse(marker), defn, "cred", errors)
        errors.should be_empty
      end

      it "rejects a marker with extra keys" do
        marker = %({"mode": "sealed", "version": 2, "set_at": "2026-09-06T10:00:00Z", "value": "x"})
        errors.clear
        type.validate(JSON.parse(marker), defn, "cred", errors)
        errors.any? { |e| e.message.includes?("exactly {mode, version, set_at}") }.should be_true
      end

      it "rejects a marker with a non-integer version" do
        marker = %({"mode": "sealed", "version": "two", "set_at": "2026-09-06T10:00:00Z"})
        errors.clear
        type.validate(JSON.parse(marker), defn, "cred", errors)
        errors.any? { |e| e.field == "cred.version" }.should be_true
      end

      it "rejects a plaintext string" do
        errors.clear
        type.validate(JSON.parse(%("hunter2")), defn, "cred", errors)
        errors.any? { |e| e.code == "invalid_format" }.should be_true
      end

      it "rejects an integer" do
        errors.clear
        type.validate(JSON.parse(%(42)), defn, "cred", errors)
        errors.any? { |e| e.code == "invalid_format" }.should be_true
      end

      it "rejects a malformed handle" do
        errors.clear
        type.validate(JSON.parse(%("sh_notaulid")), defn, "cred", errors)
        errors.any?(&.message.includes?("stage handle")).should be_true
      end
    end

    # ── Plaintext constraints (staging time) ──────────────────────────

    describe "validate_plaintext" do
      type = SecretType.new
      constrained = FieldDefinition.new(
        type: type, mode: "hash", min: 8_i64, max: 12_i64, pattern: "^[a-z]+$"
      )
      errors = [] of ValidationError

      it "accepts plaintext within min/max and pattern" do
        errors.clear
        type.validate_plaintext("abcdefghi", constrained, "cred", errors)
        errors.should be_empty
      end

      it "rejects plaintext below min" do
        errors.clear
        type.validate_plaintext("abc", constrained, "cred", errors)
        errors.any?(&.message.includes?("minimum length")).should be_true
      end

      it "rejects plaintext above max" do
        errors.clear
        type.validate_plaintext("abcdefghijklm", constrained, "cred", errors)
        errors.any?(&.message.includes?("maximum length")).should be_true
      end

      it "rejects plaintext failing the pattern" do
        errors.clear
        type.validate_plaintext("ABCdefgh", constrained, "cred", errors)
        errors.any?(&.message.includes?("pattern")).should be_true
      end
    end

    # ── Definition roundtrip ──────────────────────────────────────────

    describe "definition roundtrip" do
      it "serializes mode and ttl_seconds and re-parses equal" do
        json = %({
          "doctype": "Vault",
          "domain": "secretpage",
          "fields": {
            "pw": { "type": "secret", "mode": "hash", "min": 8 },
            "api": { "type": "secret", "mode": "token", "ttl_seconds": 3600 }
          }
        })
        defn = DoctypeDefinition.from_json(json)

        pw = defn.fields["pw"]
        pw.should_not be_nil
        pw = pw.as(FieldDefinition)
        pw.mode.should eq("hash")
        pw.ttl_seconds.should be_nil

        api = defn.fields["api"]
        api.should_not be_nil
        api = api.as(FieldDefinition)
        api.mode.should eq("token")
        api.ttl_seconds.should eq(3600_i64)

        # JSON roundtrip: serialise the fields back and re-parse.
        reparsed = FieldDefinition.from_json(pw.to_json)
        reparsed.type.should_not be_nil
        reparsed.type.as(FieldType).type_name.should eq("secret")
        reparsed.mode.should eq("hash")
        reparsed.ttl_seconds.should be_nil

        reparsed_api = FieldDefinition.from_json(api.to_json)
        reparsed_api.mode.should eq("token")
        reparsed_api.ttl_seconds.should eq(3600_i64)
      end
    end
  end
end

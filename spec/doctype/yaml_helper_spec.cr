# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "yaml"
require "json"
require "../../src/doctype/yaml_helper"

module Facet::Doctype
  describe YamlHelper do
    describe ".to_json_any" do
      it "converts a simple mapping" do
        yaml = YAML.parse(%(
          name: admin
          count: 42
        ))
        result = YamlHelper.to_json_any(yaml)
        result["name"].as_s.should eq("admin")
        result["count"].as_i.should eq(42)
      end

      it "converts nested mappings and arrays" do
        yaml = YAML.parse(%(
          permissions:
            - action: "*"
              scope: "$mine"
        ))
        result = YamlHelper.to_json_any(yaml)
        perms = result["permissions"].as_a
        perms[0]["action"].as_s.should eq("*")
        perms[0]["scope"].as_s.should eq("$mine")
      end

      it "preserves null values" do
        yaml = YAML.parse(%(
          description: null
        ))
        result = YamlHelper.to_json_any(yaml)
        result["description"].raw.should be_nil
      end

      # ── YAML 1.1 boolean-coerced keys ────────────────────────────────
      #
      # Crystal's YAML parser follows YAML 1.1: the bare words on, off, yes,
      # no, true, false are parsed as booleans. When used as hash keys, they
      # are stored as Bool, not String. yml files that use `on:` as a key
      # (e.g. RBAC permission definitions) silently lose the key name.

      it "raises on the bare word 'on' used as a key" do
        yaml = YAML.parse(%(
          permissions:
            - action: "*"
              on: "*.*"
        ))
        expect_raises(ArgumentError, /boolean/i) do
          YamlHelper.to_json_any(yaml)
        end
      end

      it "raises when 'on' appears at the top level" do
        yaml = YAML.parse(%(on: value))
        expect_raises(ArgumentError, /boolean/i) do
          YamlHelper.to_json_any(yaml)
        end
      end

      it "raises on 'off' used as a key" do
        yaml = YAML.parse(%(off: value))
        expect_raises(ArgumentError, /boolean/i) do
          YamlHelper.to_json_any(yaml)
        end
      end

      it "raises on 'yes' used as a key" do
        yaml = YAML.parse(%(yes: value))
        expect_raises(ArgumentError, /boolean/i) do
          YamlHelper.to_json_any(yaml)
        end
      end

      it "raises on 'no' used as a key" do
        yaml = YAML.parse(%(no: value))
        expect_raises(ArgumentError, /boolean/i) do
          YamlHelper.to_json_any(yaml)
        end
      end

      it "allows 'on' as a key when quoted" do
        # Quoting forces string interpretation
        yaml = YAML.parse(%(
          permissions:
            - action: "*"
              "on": "*.*"
        ))
        result = YamlHelper.to_json_any(yaml)
        result["permissions"].as_a[0]["on"].as_s.should eq("*.*")
      end
    end
  end
end

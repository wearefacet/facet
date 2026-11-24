# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "yaml"
require "../spec_helper"
require "../../src/doctype"
require "../support/db_helper"

# Seeded document views — the `core.DocumentView` children shipped in
# `data/seeds/core.DocumentView/documents.yml`.
#
# Two gates:
#   1. File-level — the seed file carries exactly the kind matrix its
#      header comment declares (which doctype gets `view` / `form` /
#      `quickView`), and every
#      template validates against its doctype's seed definition
#      (`ViewTemplateValidator.validate` — the structural check the seed pipeline
#      itself does not run).
#   2. Pipeline-level — `Doctype::Seed.seed` persists the children as
#      `core.DocumentView` projections under the right parent.
#
# The per-example truncation wipes projections, so the pipeline example
# re-runs the (idempotent) seeder itself.

# Seed paths and the kind matrix live behind private defs — top-level
# constants and public defs are program-wide across spec files (see
# doc/backend/workflow.md → Testing).
private def seed_views_file : String
  File.join(__DIR__, "..", "..", "data", "seeds", "core.DocumentView", "documents.yml")
end

private def seeds_dir : String
  File.join(__DIR__, "..", "..", "data", "seeds")
end

# The kind matrix from the plan: parent doctype → expected `kind` set.
# `core.Currency` is the precedent row.
private SEEDED_VIEW_MATRIX = {
  "iam.Account"       => ["form", "quickView", "view"],
  "iam.Roles"         => ["form", "quickView", "view"],
  "core.Webhook"      => ["form", "quickView", "view"],
  "core.DomainEditor" => ["form", "quickView", "view"],
  "core.Domain"       => ["quickView", "view"],
  "app.App"           => ["quickView", "view"],
  "app.Deployment"    => ["quickView", "view"],
  "iam.OIDCProvider"  => ["quickView", "view"],
  "core.Currency"     => ["form", "quickView", "view"],
  "core.Comment"      => ["quickView"],
}

private record SeededView, id : String, parent : String, kind : String, template : JSON::Any? do
  def self.from_json(raw : JSON::Any) : self
    content = raw["content"]
    new(
      id: raw["id"].as_s,
      parent: content["parent_doctype"].as_s,
      kind: content["kind"].as_s,
      template: content["template"]?
    )
  end
end

private def seeded_views : Array(SeededView)
  yaml = YAML.parse(File.read(seed_views_file))
  parsed = Facet::Doctype::YamlHelper.to_json_any(yaml).as_a
  parsed.map { |raw| SeededView.from_json(raw) }
end

private def definition_for(parent : String) : Facet::Doctype::DoctypeDefinition?
  path = File.join(seeds_dir, parent, "definition.yml")
  return nil unless File.exists?(path)
  yaml = YAML.parse(File.read(path))
  Facet::Doctype::DoctypeDefinition.from_json(Facet::Doctype::YamlHelper.to_json_any(yaml).to_json)
rescue ArgumentError
  # A seed using an unregistered field type cannot scope the walk — the
  # structural-only pass still runs (see seed_validity_spec).
  nil
end

module Facet::Doctype
  describe "seeded document views" do
    it "carries parent_doctype, kind, and a template on every row" do
      seeded_views.each do |view|
        view.parent.should_not be_empty, "#{view.id}: missing parent_doctype"
        view.kind.should_not be_empty, "#{view.id}: missing kind"
        view.template.should_not be_nil, "#{view.id}: missing template"
      end
    end

    it "matches the plan's kind matrix exactly" do
      views = seeded_views
      SEEDED_VIEW_MATRIX.each do |parent, expected|
        kinds = views.select(&.parent.==(parent)).map(&.kind).sort!
        kinds.should eq(expected), "#{parent}: expected kinds #{expected}, got #{kinds}"
      end
      # Every row belongs to a matrix doctype — no orphan templates.
      orphans = views.reject { |v| SEEDED_VIEW_MATRIX.has_key?(v.parent) }
      orphans.should be_empty, "views for doctypes outside the matrix: #{orphans.map(&.id)}"
    end

    it "has no duplicate id and no duplicate (parent, kind) pair" do
      views = seeded_views
      ids = views.map(&.id)
      ids.size.should eq(ids.uniq.size), "duplicate view ids in the seed file"
      pairs = views.map { |v| "#{v.parent}/#{v.kind}" }
      pairs.size.should eq(pairs.uniq.size), "duplicate parent/kind pair in the seed file"
    end

    it "validates every template against its doctype definition" do
      seeded_views.each do |view|
        defn = definition_for(view.parent)
        issues = ViewTemplateValidator.validate(view.template, defn)
        blocking = ViewTemplateValidator.errors(issues)
        blocking.should be_empty, "#{view.id}: #{blocking.map(&.message).join("; ")}"
        issues.should be_empty, "#{view.id}: #{issues.map(&.message).join("; ")}"
      end
    end

    it "persists the children through the seed pipeline" do
      with_db do |db|
        Seed.seed(db)
        SEEDED_VIEW_MATRIX.each do |parent, expected|
          kinds = [] of String
          db.query(
            "SELECT content->>'kind' FROM projections " \
            "WHERE domain = 'core' AND doc_type = 'DocumentView' " \
            "AND meta->>'parent_id' = $1 AND deleted_at IS NULL",
            parent,
          ) do |rs|
            rs.each { kinds << rs.read(String) }
          end
          kinds.sort.should eq(expected), "#{parent}: seeded kinds #{kinds}, expected #{expected}"
        end
      end
    end
  end
end

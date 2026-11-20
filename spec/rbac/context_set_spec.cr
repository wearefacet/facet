# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"

module Facet::RBAC
  describe ContextSet do
    # ── initialization ─────────────────────────────────────────────────────

    describe "#initialize" do
      it "stores all fields" do
        cs = ContextSet.new(
          name: "my_teams",
          from: "TeamMembership",
          where: {"account" => "$self"},
          select_field: "team",
        )
        cs.name.should eq("my_teams")
        cs.from.should eq("TeamMembership")
        cs.where.should eq({"account" => "$self"})
        cs.select_field.should eq("team")
      end
    end

    # ── dependencies ───────────────────────────────────────────────────────

    describe "#dependencies" do
      it "returns empty when where has no $set references" do
        cs = ContextSet.new(
          name: "my_teams",
          from: "TeamMembership",
          where: {"account" => "$self"},
          select_field: "team",
        )
        cs.dependencies.should be_empty
      end

      it "returns a single dependency" do
        cs = ContextSet.new(
          name: "my_projects",
          from: "Project",
          where: {"team" => "$my_teams"},
          select_field: "id",
        )
        cs.dependencies.should eq(["my_teams"])
      end

      it "returns multiple dependencies" do
        cs = ContextSet.new(
          name: "complex",
          from: "Task",
          where: {"team" => "$my_teams", "project" => "$my_projects"},
          select_field: "id",
        )
        cs.dependencies.should eq(["my_teams", "my_projects"])
      end

      it "excludes $self from dependencies" do
        cs = ContextSet.new(
          name: "mixed",
          from: "Task",
          where: {"account" => "$self", "team" => "$my_teams"},
          select_field: "id",
        )
        cs.dependencies.should eq(["my_teams"])
      end
    end

    # ── to_s ───────────────────────────────────────────────────────────────

    describe "#to_s" do
      it "returns a human-readable string" do
        cs = ContextSet.new(
          name: "my_teams",
          from: "TeamMembership",
          where: {"account" => "$self"},
          select_field: "team",
        )
        cs.to_s.should contain("ContextSet")
        cs.to_s.should contain("my_teams")
        cs.to_s.should contain("TeamMembership")
      end
    end
  end
end

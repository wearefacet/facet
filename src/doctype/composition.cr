# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "./doctype_definition"
require "./definition_store"

module Facet
  module Doctype
    # Bundle-level composition check.
    #
    # Composition has exactly one spelling: the parent declares a
    # `children:` entry AND the child declares `member_of` back at the
    # parent. `Composition.validate` runs that rule over a whole set of
    # definitions of one domain — a draft bundle about to publish, or an
    # imported archive — where every doctype of the domain is present and
    # the graph can be closed without registry lookups.
    #
    # Per-definition aggregation rules (`aggregate_root` vs `member_of`)
    # live in `Doctype::Validation`; live-domain diagnostics in
    # `Doctype::Check`. This module only sees the mutual edge, because
    # only a bundle can prove reciprocity in both directions at once.
    module Composition
      # One reciprocity failure.
      record Problem,
        doctype : String, # the definition the problem was found on
        message : String

      # Validates the composition graph of one domain's definitions.
      # Returns an empty array when every `children` entry is reciprocated
      # by a `member_of` on its target and every `member_of` has a
      # matching `children` entry on its parent.
      def self.validate(definitions : Array(DoctypeDefinition)) : Array(Problem)
        by_name = definitions.to_h { |d| {d.doctype, d} }
        problems = [] of Problem

        definitions.each do |definition|
          # (1) every children entry targets a member_of-declaring child.
          definition.children.each do |rel_name, child|
            target = by_name[child.doctype]?
            if target.nil?
              problems << Problem.new(
                doctype: definition.doctype,
                message: "children entry '#{rel_name}' targets doctype '#{child.doctype}' which is not defined in this domain",
              )
            elsif target.member_of != definition.doctype
              problems << Problem.new(
                doctype: definition.doctype,
                message: "children entry '#{rel_name}' targets doctype '#{child.doctype}' which does not declare member_of '#{definition.doctype}' — composition must be mutual (children entry on the parent, member_of on the child)",
              )
            end
          end

          # (2) every member_of names a parent that owns this doctype.
          if parent_name = definition.member_of
            next if parent_name.empty?
            parent = by_name[parent_name]?
            if parent.nil?
              problems << Problem.new(
                doctype: definition.doctype,
                message: "member_of '#{parent_name}' names a doctype that is not defined in this domain",
              )
            elsif parent.children.none? { |_, c| c.doctype == definition.doctype }
              problems << Problem.new(
                doctype: definition.doctype,
                message: "member_of '#{parent_name}' has no matching children entry on '#{parent_name}' — composition must be mutual (children entry on the parent, member_of on the child)",
              )
            end
          end
        end

        problems
      end
    end
  end
end

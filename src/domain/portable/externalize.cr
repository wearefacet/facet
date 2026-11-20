# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Domain
    module Portable
      # Describes how a bundle entry's Lua script strings are externalized
      # to co-located sidecar files referenced by `!read_file`.
      #
      # The writer (`Archive.write_entry`) consults a `Policy` while emitting
      # an entry's `content`. When a string scalar sits at a path the policy
      # names, the writer writes the string to a sidecar file and emits
      # `!read_file <filename>` in its place. The reader (`Util::YamlInclude`)
      # expands that reference back to the file's literal contents, so the
      # round-trip is lossless.
      #
      # Two call sites externalize today:
      #
      # * a doctype's lifecycle `script` → `doctypes/{Qualified}.lua`
      # * a domain hook's `script` → `hooks/{i}-{hook_id}.lua`
      #
      # Documents and views never externalize — their content is data, not
      # definition, and stays inline.
      module Externalize
        # One externalizable script: the JSON path of keys into the content
        # tree, and the sidecar filename (relative to the entry YAML's
        # directory).
        record Spec,
          path : Array(String),
          filename : String

        # A set of `Spec`s. A `nil` policy (or an empty policy) means "inline
        # everything" — the writer's default for documents and views.
        class Policy
          getter specs : Array(Spec)

          def initialize(@specs : Array(Spec))
          end

          # Returns the sidecar filename for a script at `path`, or `nil`
          # when the path is not externalized.
          def filename_for(path : Array(String)) : String?
            spec = specs.find { |s| s.path == path }
            spec.try(&.filename)
          end
        end

        # Builds the policy for a doctype entry: externalize `content.script`
        # to `{qualified}.lua`, co-located with the doctype YAML.
        def self.doctype_policy(qualified : String) : Policy
          Policy.new([Spec.new(["script"], "#{qualified}.lua")])
        end

        # Builds the policy for a domain entry: externalize every hook's
        # `content.hooks[i].script` to `hooks/{i}-{hook_id}.lua`. Hooks
        # without a script, or with an empty script, are left inline (they are
        # invalid anyway — `Hooks::Validator` requires a non-empty script).
        #
        # The sidecar filename is prefixed with the hook's array index so two
        # distinct ids that sanitise to the same filename never collide. The
        # sanitised id is kept as a readable suffix.
        def self.domain_policy(content : JSON::Any) : Policy
          specs = [] of Spec
          hooks = content["hooks"]?.try(&.as_a?)
          return Policy.new(specs) unless hooks
          hooks.each_with_index do |hook, i|
            script = hook["script"]?.try(&.as_s?)
            next if script.nil? || script.empty?
            id = hook["id"]?.try(&.as_s?) || "hook_#{i}"
            specs << Spec.new(["hooks", i.to_s, "script"], "hooks/#{i}-#{sanitize_filename(id)}.lua")
          end
          Policy.new(specs)
        end

        # Sanitises a hook id into a filesystem-safe filename segment. Any
        # character outside `[A-Za-z0-9_.-]` (notably `/`, which would form a
        # path segment) is replaced with `_`, so the result never contains a
        # path separator and cannot escape the `hooks/` directory.
        private def self.sanitize_filename(id : String) : String
          id.gsub(/[^A-Za-z0-9_.-]/, '_')
        end
      end
    end
  end
end

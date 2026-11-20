# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"

# Pluggable YAML tag handlers for `Facet::Util::YamlInclude`.
#
# A tag handler owns one YAML tag: it declares the keyword it responds to
# (`tag`) and rewrites a tagged scalar to its expanded value (`expand`).
# Handlers are stateless value types; callers pass a list of instances to
# `YamlInclude.parse` / `YamlInclude.parse_string`, and the parser dispatches
# scalars by tag. A tag that no handler in the list declares is rejected —
# the caller's list *is* the policy.
#
# ## Built-in handlers
#
# ### `ReadFileTag` — `!read_file <relative-path>`
#
# Rewrites the scalar to the literal contents of the referenced file. Paths
# are interpreted relative to the **directory** of the YAML file that declares
# the tag, and are jail-restricted to that directory and its descendants:
# no `..` segment, no absolute paths, no symlinks pointing outside. This
# treats the YAML file's own directory as the root of its reachable file
# system — a bundle entry at `doctypes/crm.Deal.yml` may reference
# `crm.Deal.lua` or `fragments/x.lua`, but never `../scripts/anything.lua`.
#
# The referenced file is *not* parsed as YAML — `!read_file` is a
# text-substitution preprocessor, not a YAML composition directive. This
# keeps non-YAML payloads (e.g. a Lua lifecycle script containing `:` or `-`)
# round-tripping verbatim, and avoids needing to know the referenced file's
# format ahead of time. Nested `!read_file` directives inside a referenced
# file are therefore not resolved — by design. If you need composition,
# declare each `!read_file` in the YAML entry directly.
#
# ### `EnvTag` — `!env NAME`
#
# Rewrites the scalar to the value of the environment variable *NAME*. Used
# by `Facet::Config.load` so secrets (passwords, tokens, API keys) can be
# injected into `config.{env}.yml` without being checked in. A missing
# variable raises at parse time — fail loud, never silently substitute an
# empty value.
#
# ### `EnvOptTag` — `!env? NAME`
#
# Rewrites the scalar to the value of the environment variable *NAME*, or to
# **no value** when the variable is unset — the key then reads exactly like
# an explicit `null` in the file, and the consuming config section applies
# its own default. Used where absence is a supported posture: the AI
# Assistant ships disabled when its `FACET_AI_*` variables are not set, and
# the deployment enables it by exporting them (or by pinning the runtime
# settings document) without editing the config file.
#
# `EnvTag` and `EnvOptTag` are **config-only** handlers. Bundle YAML is
# untrusted authoring content: expanding env variables there would let an
# imported bundle exfiltrate secrets into the database. Bundle parsing
# therefore never receives an `EnvTag` instance, and an `!env` scalar in a
# bundle is rejected as an unknown tag.
module Facet::Util::YamlTag
  # Raised when a tag handler cannot expand a scalar (malformed reference,
  # missing file, jail escape, unset variable). Reported with the including
  # YAML file's path so authors can locate the offending directive.
  class ExpandError < ::Exception
    getter source_file : String?

    def initialize(@source_file : String?, message : String)
      super("#{source_file || "<string>"}: #{message}")
    end
  end

  # Context handed to a handler for each tagged scalar it expands.
  #
  # * `source_file` is the path of the YAML file being parsed, or `nil` when
  #   the input is an in-memory string. Used for error messages.
  # * `base_dir` is the directory of that YAML file, or `nil` for in-memory
  #   strings. Handlers that need file semantics (e.g. `ReadFileTag`) resolve
  #   relative references against it.
  record Context, source_file : String?, base_dir : String?

  # A single YAML tag handler. `tag` is the keyword the handler responds to,
  # including the leading `!` (e.g. `"!env"`). `expand` rewrites the scalar's
  # value; the parser applies the returned string and clears the tag.
  #
  # Returning nil from `expand` means *no value*: the parser rewrites the
  # scalar to a plain null node, so the containing key reads exactly like an
  # explicit `null` in the file and the consumer applies its own default.
  # That is a deliberate contract, not a fallback path — a handler whose
  # expansion must always produce a value annotates the return type `String`
  # (as `EnvTag` and `ReadFileTag` do), and the compiler then refuses any
  # nil-returning branch.
  abstract struct Handler
    abstract def tag : String

    abstract def expand(node : YAML::Nodes::Scalar, ctx : Context) : String?
  end

  # Expands `!read_file <relative-path>` to the referenced file's literal
  # contents. See the module docs for the jail rules.
  struct ReadFileTag < Handler
    def tag : String
      "!read_file"
    end

    def expand(node : YAML::Nodes::Scalar, ctx : Context) : String
      base_dir = ctx.base_dir
      unless base_dir
        raise ExpandError.new(ctx.source_file, "!read_file requires a file context — it cannot be used in in-memory YAML")
      end

      ref = node.value
      target = resolve_target(ref, base_dir, ctx.source_file)
      File.read(target)
    end

    # Resolves *ref* (relative to *base_dir*) to an absolute canonical path
    # and validates that the result stays inside *base_dir* or one of its
    # descendants. The check is enforced in two layers:
    #
    # 1. **Lexical `..` rejection.** Split the reference into segments and
    #    reject any `..` segment outright. This prevents even the start of an
    #    upward traversal, before any symlink resolution is consulted.
    # 2. **Canonical prefix check.** `File.realpath` resolves symlinks on
    #    disk; the resolved path must start with the jail root + `/`. A
    #    symlink inside the jail that points outside is caught here.
    #
    # Absolute paths are rejected because `File.expand_path` would treat them
    # as already-canonical and bypass the relative-to-`base_dir` semantics.
    private def resolve_target(ref : String, base_dir : String, source_file : String?) : String
      if ref.empty?
        raise ExpandError.new(source_file, "!read_file referenced an empty path")
      end

      if Path.new(ref).absolute?
        raise ExpandError.new(source_file, "!read_file '#{ref}' is absolute — only relative paths are allowed")
      end

      # Layer 1: reject any `..` segment lexically.
      Path.new(ref).parts.each do |part|
        if part == ".."
          raise ExpandError.new(source_file, "!read_file '#{ref}' escapes the YAML directory (contains '..')")
        end
      end

      # Canonicalise the jail root so the prefix check on referenced paths is
      # reliable even when the YAML file sits behind a symlink in its own path.
      root = File.realpath(base_dir) rescue base_dir
      candidate = File.expand_path(File.join(base_dir, ref))

      # Layer 2: canonical symlink resolution + jail prefix check.
      canonical =
        begin
          File.realpath(candidate)
        rescue File::NotFoundError
          # The file is missing — fall back to the lexical candidate so the
          # missing-file branch below produces a clearer error than a raw
          # NotFoundError from realpath.
          candidate
        end

      unless canonical.starts_with?(root + File::SEPARATOR) || canonical == root
        raise ExpandError.new(source_file, "!read_file '#{ref}' escapes the YAML directory #{root}")
      end

      unless File.file?(canonical)
        raise ExpandError.new(source_file, "!read_file '#{ref}' not found (resolved to #{canonical})")
      end

      canonical
    end
  end

  # Expands `!env NAME` to the value of the named environment variable.
  # Fails loud when the variable is not set — the author explicitly asked for
  # that variable, and a silent empty value would flow into config and fail
  # far from the cause.
  struct EnvTag < Handler
    def tag : String
      "!env"
    end

    def expand(node : YAML::Nodes::Scalar, ctx : Context) : String
      name = node.value
      if name.empty?
        raise ExpandError.new(ctx.source_file, "!env referenced an empty variable name")
      end

      value = ENV[name]?
      unless value
        raise ExpandError.new(ctx.source_file, "!env '#{name}' is not set in the environment")
      end

      value
    end
  end

  # Expands `!env? NAME` to the value of the named environment variable, or
  # to no value when it is unset. See the module docs for the posture this
  # serves.
  struct EnvOptTag < Handler
    def tag : String
      "!env?"
    end

    def expand(node : YAML::Nodes::Scalar, ctx : Context) : String?
      name = node.value
      if name.empty?
        raise ExpandError.new(ctx.source_file, "!env? referenced an empty variable name")
      end

      ENV[name]?
    end
  end
end

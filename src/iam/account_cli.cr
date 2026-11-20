# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"
require "json"
require "pg"
require "../database"
require "../document"
require "../util/script_helpers"
require "../rbac"
require "./invite"

module Facet
  module IAM
    # CLI subcommands for inspecting and repairing account / role assignments.
    #
    # These are operational tools for an IT operator fixing a broken
    # assignment, not a user-facing management surface. They bypass RBAC by
    # design (system-tier) and print plain text to stdout.
    #
    # Usage:
    #   facet accounts:list
    #   facet accounts:create <email> [--name <display name>] [--role <role>]
    #   facet roles:list
    #   facet roles:add <account> <role>
    module AccountCLI
      # Parsed options for `accounts:create`. `name` is already defaulted
      # to the email; `role` is nil when the operator assigns none.
      private record CreateOptions, email : String, name : String, role : String?

      # Creates a normal (non-admin) account and prints a one-time
      # password. Returns the process exit code.
      #
      # The account document goes through the standard document pipeline
      # (`Document::Create` — field validation, the unique-email
      # constraint, projection GUCs, buffered events), so its shape is
      # the same as an account created through the HTTP surface. The
      # credential step reuses the temporary-password bootstrap
      # (`Invite.generate_temporary_password`): a generated one-time
      # password on the `password` slot, `must_change_pw: true`, and the
      # `temp_password_generated` login event. The plaintext prints
      # exactly once — it is never stored in plaintext and never logged.
      def self.create_account(args : Array(String)) : Int32
        options = parse_create_args(args)
        return 1 if options.nil?

        Database.with_db(:read_write) do |db|
          created = create_account_document(db, options)
          next 1 if created.nil?

          result = Invite.generate_temporary_password(db, created[:id])
          case result
          in Invite::Generated
            puts "Account created."
            puts "  email:    #{created[:email]}"
            puts "  id:       #{created[:id]}"
            puts "  password: #{result.password}"
            puts
            puts "This password is shown once. It is not stored in plaintext and not logged."
            puts "The account must change the password at first login."
            0
          in Facet::ServiceError
            puts "Error: the account was created (id #{created[:id]}), but generating the one-time password failed: #{result.message}"
            puts "Set a credential through the invite flow (web UI or REST API)."
            1
          end
        end
      end

      # Parses the `accounts:create` argument list. Returns nil (with the
      # error printed) when the arguments are unusable.
      private def self.parse_create_args(args : Array(String)) : CreateOptions?
        email : String? = nil
        name : String? = nil
        role : String? = nil
        bad_option : String? = nil

        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet accounts:create <email> [--name <display name>] [--role <role>]"

          parser.on("--name NAME", "Display name (defaults to the email)") do |value|
            name = value
          end

          parser.on("--role ROLE", "Role to assign at creation (id or bare name)") do |value|
            role = value
          end

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end

          parser.invalid_option { |opt| bad_option = opt }
          parser.missing_option { |opt| bad_option = opt }
          parser.unknown_args { |pos| email = pos.first? }
        end

        if bad_option
          puts "Error: unknown or incomplete option '#{bad_option}'."
          puts "Usage: facet accounts:create <email> [--name <display name>] [--role <role>]"
          return nil
        end

        # The parser writes into captured locals, so rebind to plain
        # locals before the nil checks — Crystal cannot narrow a captured
        # variable's type.
        clean_email = email.try(&.strip) || ""
        if clean_email.empty?
          puts "Error: an email address is required."
          puts "Usage: facet accounts:create <email> [--name <display name>] [--role <role>]"
          return nil
        end

        clean_name = name.try(&.strip) || ""
        display_name = clean_name.empty? ? clean_email : clean_name
        clean_role = role.try(&.strip) || ""
        role_arg = clean_role.empty? ? nil : clean_role

        CreateOptions.new(email: clean_email, name: display_name, role: role_arg)
      end

      # Creates the `iam.Account` document. When a role was given and
      # resolves, it is the account's only role and its `default_role`
      # (the same first-role rule `roles:add` applies). Returns the
      # document id and email, or nil after printing the error.
      private def self.create_account_document(
        db : DB::Connection,
        options : CreateOptions,
      ) : NamedTuple(id: String, email: String)?
        role_id : String? = nil
        if role_arg = options.role
          role = resolve_role(db, role_arg)
          if role.nil?
            puts "Error: role not found: #{role_arg}"
            puts "Inspect roles with 'facet roles:list'."
            return nil
          end
          role_id = role[:id]
        end

        content = if role_id
                    {
                      "email"        => options.email,
                      "name"         => options.name,
                      "roles"        => [role_id],
                      "default_role" => role_id,
                    }.to_json
                  else
                    # No role: omit `roles` entirely. An empty array
                    # round-trips the Lua create hook as an empty object
                    # (`{}` — a Lua table is both), a non-array shape the
                    # readers must then tolerate. An absent field means
                    # "no roles" to every reader.
                    {
                      "email" => options.email,
                      "name"  => options.name,
                    }.to_json
                  end

        # No explicit `status`: the `iam.Account` create hook forces the
        # bootstrap status `pending` for human accounts — the same shape
        # an HTTP-created account lands in. The first full login flips it
        # to `active`.

        result = Document::Create.call(
          db,
          "iam",
          "Account",
          content,
          RBAC::AuthContext.system,
          doc_id: Util::ScriptHelpers.ulid,
        )
        case result
        in Document::Create::Result
          {id: result.projection.id, email: options.email}
        in Facet::ServiceError
          print_create_error(result, options.email)
          nil
        end
      end

      # True when the create failed on the account email's unique
      # constraint (the pipeline surfaces it as a 422 with a structured
      # `unique` error on the email field).
      private def self.email_collision?(error : Facet::ServiceError) : Bool
        return false unless error.status == 422
        details = error.details
        return false unless details
        details.any? { |d| d.code == "unique" && d.field == "email" }
      end

      # Prints the create failure. A duplicate email gets the friendly
      # recovery hint; everything else prints the structured error.
      private def self.print_create_error(error : Facet::ServiceError, email : String) : Nil
        if email_collision?(error)
          puts "Error: an active account with the email '#{email}' already exists."
          puts "Inspect accounts with 'facet accounts:list'."
        else
          details = error.details.try(&.map { |d| "#{d.field}: #{d.message}" }.join("; "))
          puts "Error (#{error.status}): #{error.message}#{details ? " — #{details}" : ""}"
        end
      end

      # Lists every `iam.Account` document: id, email, display name, status,
      # and the assigned role ids. Sorted by email.
      def self.list_accounts : Nil
        Database.with_db(:read_only) do |db|
          result = Document::List.call(
            db,
            "iam",
            "Account",
            sort: ["email"],
            auth_context: RBAC::AuthContext.system,
          )
          case result
          in Document::List::Result
            if result.items.empty?
              puts "No accounts found."
              return
            end
            result.items.each do |proj|
              content = proj.content.as_h
              puts [
                proj.id,
                content["email"]?.try(&.as_s?) || "(no email)",
                content["name"]?.try(&.as_s?) || "(no display name)",
                content["status"]?.try(&.as_s?) || "active",
                (content["roles"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String).join(", "),
              ].join("\t")
            end
          in Facet::ServiceError
            abort "Error: #{result.message}"
          in Document::List::AggregateResult
            # Unreachable: the CLI never requests an aggregate. The union
            # member exists because `Document::List.call` can return one.
            abort "Error: unexpected aggregate result"
          end
        end
      end

      # Lists every `iam.Roles` document: id and name. Sorted by name.
      def self.list_roles : Nil
        Database.with_db(:read_only) do |db|
          result = Document::List.call(
            db,
            "iam",
            "Roles",
            sort: ["name"],
            auth_context: RBAC::AuthContext.system,
          )
          case result
          in Document::List::Result
            if result.items.empty?
              puts "No roles found."
              return
            end
            result.items.each do |proj|
              content = proj.content.as_h
              puts "#{proj.id}\t#{content["name"]?.try(&.as_s?) || "(no name)"}"
            end
          in Facet::ServiceError
            abort "Error: #{result.message}"
          in Document::List::AggregateResult
            # Unreachable: the CLI never requests an aggregate. The union
            # member exists because `Document::List.call` can return one.
            abort "Error: unexpected aggregate result"
          end
        end
      end

      # Assigns a role to an account.
      #
      # `account` is resolved by id first, then by email. `role` is resolved
      # by id (`iam.Roles.admin`) first, then by bare name (`admin`). The
      # role is appended to the account's `roles` array when absent. When the
      # account had no roles yet, the assigned role becomes `default_role`,
      # mirroring the frontend `assignRole` helper.
      def self.add_role(args : Array(String)) : Nil
        account_arg = args[0]?
        role_arg = args[1]?
        if account_arg.nil? || account_arg.empty? || role_arg.nil? || role_arg.empty?
          puts "Error: an account and a role are required."
          puts "Usage: facet roles:add <account> <role>"
          exit 1
        end

        Database.with_db(:read_write) do |db|
          account = resolve_account(db, account_arg)
          abort "Error: account not found: #{account_arg}" if account.nil?

          role = resolve_role(db, role_arg)
          abort "Error: role not found: #{role_arg}" if role.nil?

          assign(db, account, role)
        end
      end

      # Persists the role assignment. No-op when the role is already assigned.
      # When the account had no roles, the assigned role becomes `default_role`
      # so login does not fall through to "first assigned" later behaviour.
      private def self.assign(
        db : DB::Connection,
        account : NamedTuple(id: String, email: String, roles: Array(String), default_role: String?),
        role : NamedTuple(id: String, name: String),
      ) : Nil
        current_roles = account[:roles]
        if current_roles.includes?(role[:id])
          puts "Account #{account[:email]} already has role #{role[:id]}."
          return
        end

        next_roles = current_roles + [role[:id]]
        patch = {"roles" => next_roles}.to_json
        if current_roles.empty? && account[:default_role].nil?
          patch = {"roles" => next_roles, "default_role" => role[:id]}.to_json
        end

        result = Document::Update.call(
          db,
          "iam",
          "Account",
          account[:id],
          patch,
          auth_context: RBAC::AuthContext.system,
        )
        case result
        in Document::Update::Result
          puts "Assigned role #{role[:id]} to account #{account[:email]}."
        in Facet::ServiceError
          abort "Error: #{result.message}"
        end
      end

      # Resolves an account argument to its projection id, email, roles, and
      # default_role. Tries the id first, then the email.
      private def self.resolve_account(
        db : DB::Connection,
        account_arg : String,
      ) : NamedTuple(id: String, email: String, roles: Array(String), default_role: String?)?
        row = db.query_one?(
          <<-SQL,
            SELECT id, content->>'email', content->'roles', content->>'default_role'
            FROM projections
            WHERE domain = 'iam' AND doc_type = 'Account'
              AND deleted_at IS NULL
              AND (id = $1 OR LOWER(content->>'email') = LOWER($1))
          SQL
          account_arg
        ) do |rs|
          id = rs.read(String)
          email = rs.read(String?)
          roles_raw = rs.read(JSON::Any?)
          default_role = rs.read(String?)
          roles = roles_raw.try(&.as_a?.try(&.map(&.as_s))) || [] of String
          {id: id, email: email || id, roles: roles, default_role: default_role}
        end
        row
      end

      # Resolves a role argument to its projection id and name. Tries the id
      # (`iam.Roles.admin`) first, then the bare name (`admin`).
      private def self.resolve_role(
        db : DB::Connection,
        role_arg : String,
      ) : NamedTuple(id: String, name: String)?
        row = db.query_one?(
          <<-SQL,
            SELECT id, content->>'name'
            FROM projections
            WHERE domain = 'iam' AND doc_type = 'Roles'
              AND deleted_at IS NULL
              AND (id = $1 OR content->>'name' = $1)
          SQL
          role_arg
        ) do |rs|
          id = rs.read(String)
          name = rs.read(String?) || id
          {id: id, name: name}
        end
        row
      end
    end
  end
end

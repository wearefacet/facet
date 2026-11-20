# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "option_parser"
require "../database"
require "../doctype/definition_store"
require "./seed"

module Facet
  module IAM
    # CLI runner for the first-admin bootstrap (`facet seed:admin`).
    #
    # Takes the admin email from the first argument, or from the
    # `SEED_ADMIN_EMAIL` environment variable when no argument is given.
    # Flags are refused (`--help` prints usage and exits 0, the same
    # contract `accounts:create` applies). The email must pass the
    # `iam.Account` email field's own validation before the write: the seed
    # writes raw (`Mutation::Client.create`), so the shape check the
    # document pipeline would apply runs here. Prints the generated one-time
    # password exactly once.
    module SeedCLI
      private USAGE_LINES = [
        "Usage: facet seed:admin <email>",
        "   or: set SEED_ADMIN_EMAIL and run 'facet seed:admin'",
      ]

      # Creates the first admin and prints the one-time credential.
      # Returns the process exit code.
      def self.seed_admin(args : Array(String)) : Int32
        email = parse_email(args)
        return 1 if email.nil?

        rejection = Database.with_db(:read_only) do |db|
          email_rejection(db, email)
        end
        unless rejection.nil?
          puts "Error: #{rejection}"
          print_usage
          return 1
        end

        created = Database.with_db(:read_write) do |db|
          Seed.seed_admin(db, email)
        end

        if created.nil?
          puts "Error: an active account with the email '#{email}' already exists."
          puts "Inspect accounts with 'facet accounts:list'. To recover access, use the password-reset flow."
          return 1
        end

        puts "Admin account created."
        puts "  email:    #{created.email}"
        puts "  id:       #{created.id}"
        puts "  password: #{created.password}"
        puts
        puts "This password is shown once. It is not stored in plaintext and not logged."
        puts "The account must change the password at first login."
        0
      end

      # Parses the `seed:admin` argument list. Returns the email — stripped
      # and lowercased, the stored form every login lookup compares — or
      # nil (with the error printed) when the arguments are unusable.
      # Mirrors `accounts:create`: `--help` prints usage and exits 0, an
      # unknown or incomplete option is refused, and exactly one positional
      # argument is accepted.
      private def self.parse_email(args : Array(String)) : String?
        positional = [] of String
        bad_option : String? = nil

        OptionParser.parse(args) do |parser|
          parser.banner = "Usage: facet seed:admin <email>"

          parser.on("-h", "--help", "Show help") do
            puts parser
            exit 0
          end

          parser.invalid_option { |opt| bad_option = opt }
          parser.missing_option { |opt| bad_option = opt }
          parser.unknown_args { |pos| positional = pos }
        end

        if bad_option
          puts "Error: unknown or incomplete option '#{bad_option}'."
          print_usage
          return nil
        end

        if positional.size > 1
          puts "Error: seed:admin takes a single email argument."
          print_usage
          return nil
        end

        raw = positional[0]? || ENV["SEED_ADMIN_EMAIL"]?
        if raw.nil? || raw.strip.empty?
          puts "Error: an email address is required."
          print_usage
          return nil
        end

        # Lowercased to the stored form: the `iam.Account` create hook
        # lowercases the email on the pipeline path, and every lookup
        # (login, password reset, OIDC resolution) compares lowercase.
        raw.strip.downcase
      end

      # Runs the `iam.Account` email field's own validation on *email* —
      # the same check `Document::Create` applies on the pipeline path. The
      # raw write below bypasses the pipeline, so the shape check runs
      # here, against the live definition (installed by `facet
      # seed:core`). Returns nil when the address is acceptable, otherwise
      # the operator-facing error text.
      private def self.email_rejection(db : DB::Connection, email : String) : String?
        definition = Doctype::DefinitionStore.fetch(db, "iam.Account")
        if definition.nil?
          return "the iam.Account doctype definition is not in the database — " \
                 "run 'facet migrate seed:core' first"
        end

        field = definition.fields["email"]?
        if field.nil?
          return "the iam.Account definition declares no 'email' field"
        end

        field_type = field.type
        if field_type.nil?
          return "the iam.Account 'email' field declares no type"
        end

        errors = [] of ValidationError
        field_type.validate(JSON::Any.new(email), field, "email", errors)
        return nil if errors.empty?

        "the email '#{email}' does not pass the account email validation: " +
          errors.map(&.message).join("; ")
      end

      private def self.print_usage : Nil
        USAGE_LINES.each { |line| puts line }
      end
    end
  end
end

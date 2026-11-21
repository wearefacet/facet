# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "log/spec"
require "../src/config"

def build_config(host : String? = nil, domains : Facet::Config::DomainsConfig? = nil) : Facet::Config
  Facet::Config.new(
    artifact_grant_secret: "test-secret",
    host: host || "localhost:3000",
    domains: domains || Facet::Config::DomainsConfig.new,
    secrets: Facet::Secrets::Config.new(master_key: TEST_MASTER_KEY),
  )
end

def build_mfa_config_yaml(enforcement : String?) : YAML::Any
  if enforcement
    YAML.parse(<<-YAML
      event:
        url: "redis://localhost:6379/1"
      artifact_base_url: "http://localhost:3001"
      artifact_grant_secret: "test-grant-secret"
      artifact:
        storage:
          type: filesystem
          directory: tmp/uploads/test/store
      secrets:
        master_key: "#{TEST_MASTER_KEY}"
      iam:
        mfa:
          enforcement: "#{enforcement}"
      YAML
    )
  else
    YAML.parse(<<-YAML
      event:
        url: "redis://localhost:6379/1"
      artifact_base_url: "http://localhost:3001"
      artifact_grant_secret: "test-grant-secret"
      artifact:
        storage:
          type: filesystem
          directory: tmp/uploads/test/store
      secrets:
        master_key: "#{TEST_MASTER_KEY}"
      YAML
    )
  end
end

# Builds a full YAML document carrying an optional `database:` block.
def build_database_config_yaml(database_block : String = "") : YAML::Any
  YAML.parse(<<-YAML
    event:
      url: "redis://localhost:6379/1"
    artifact_base_url: "http://localhost:3001"
    artifact_grant_secret: "test-grant-secret"
    artifact:
      storage:
        type: filesystem
        directory: tmp/uploads/test/store
    secrets:
      master_key: "#{TEST_MASTER_KEY}"
    #{database_block}
    YAML
  )
end

# Builds a full YAML document carrying an `iam:` block (the block includes
# the `iam:` key itself so callers can shape nested sections freely).
def build_iam_config_yaml(iam_block : String) : YAML::Any
  YAML.parse(<<-YAML
    event:
      url: "redis://localhost:6379/1"
    artifact_base_url: "http://localhost:3001"
    artifact_grant_secret: "test-grant-secret"
    artifact:
      storage:
        type: filesystem
        directory: tmp/uploads/test/store
    secrets:
      master_key: "#{TEST_MASTER_KEY}"
    #{iam_block}
    YAML
  )
end

# Builds a full YAML document carrying an optional raw block (the block is
# spliced verbatim after the required sections, so callers can shape any
# top-level section; an empty block exercises the section-absent defaults).
def build_yaml_config(raw_block : String) : YAML::Any
  YAML.parse(<<-YAML
    event:
      url: "redis://localhost:6379/1"
    artifact_base_url: "http://localhost:3001"
    artifact_grant_secret: "test-grant-secret"
    artifact:
      storage:
        type: filesystem
        directory: tmp/uploads/test/store
    secrets:
      master_key: "#{TEST_MASTER_KEY}"
    #{raw_block}
    YAML
  )
end

# Builds a full YAML document carrying an optional `mail:` block (the
# block includes the `mail:` key itself so callers can shape the section
# freely; an empty block exercises the section-absent defaults).
def build_mail_config_yaml(mail_block : String = "") : YAML::Any
  YAML.parse(<<-YAML
    event:
      url: "redis://localhost:6379/1"
    artifact_base_url: "http://localhost:3001"
    artifact_grant_secret: "test-grant-secret"
    artifact:
      storage:
        type: filesystem
        directory: tmp/uploads/test/store
    secrets:
      master_key: "#{TEST_MASTER_KEY}"
    #{mail_block}
    YAML
  )
end

# Sets APP_ENV=production for the block and restores the previous value
# after — the config loader reads the environment at parse time.
def with_production_env(&)
  previous = ENV["APP_ENV"]?
  ENV["APP_ENV"] = "production"
  yield
ensure
  if previous
    ENV["APP_ENV"] = previous
  else
    ENV.delete("APP_ENV")
  end
end

# Sets FACET_CONFIG_FILE for the block, restoring the previous value (or
# its absence) after — the config resolver reads the variable at load
# time. Private: owned by this spec file (file-scoped def).
private def with_facet_config_file(path : String?, &) : Nil
  previous = ENV["FACET_CONFIG_FILE"]?
  if path
    ENV["FACET_CONFIG_FILE"] = path
  else
    ENV.delete("FACET_CONFIG_FILE")
  end
  yield
ensure
  if previous
    ENV["FACET_CONFIG_FILE"] = previous
  else
    ENV.delete("FACET_CONFIG_FILE")
  end
  Facet::Config.reset!
end

module Facet
  describe Config do
    describe ".load" do
      it "raises when the config file for APP_ENV does not exist" do
        previous = ENV["APP_ENV"]?
        ENV["APP_ENV"] = "does-not-exist"
        begin
          message = /Missing config file for APP_ENV=does-not-exist/
          expect_raises(Exception, message) { Facet::Config.load }
        ensure
          if previous
            ENV["APP_ENV"] = previous
          else
            ENV.delete("APP_ENV")
          end
          Facet::Config.reset!
        end
      end

      it "prefers FACET_CONFIG_FILE over the default resolution" do
        file = File.tempfile("facet-config", ".yml")
        begin
          # A full minimal config with a distinctive marker value — the
          # loaded instance must come from this file, not from any
          # config.{APP_ENV}.yml next to the binary.
          file.puts <<-YAML
            event:
              url: "redis://localhost:6379/1"
            host: "facet-config-file-host:3000"
            artifact_base_url: "http://localhost:3001"
            artifact_grant_secret: "test-grant-secret"
            artifact:
              storage:
                type: filesystem
                directory: tmp/uploads/test/store
            secrets:
              master_key: "#{TEST_MASTER_KEY}"
          YAML
          file.flush

          with_facet_config_file(file.path) do
            # A default resolution would fail loud here — the explicit
            # path wins.
            previous = ENV["APP_ENV"]?
            ENV["APP_ENV"] = "does-not-exist"
            begin
              cfg = Facet::Config.load
              cfg.host.should eq("facet-config-file-host:3000")
            ensure
              if previous
                ENV["APP_ENV"] = previous
              else
                ENV.delete("APP_ENV")
              end
            end
          end
        ensure
          File.delete?(file.path)
        end
      end

      it "raises when FACET_CONFIG_FILE is set but the file is missing" do
        with_facet_config_file("/no/such/facet-config-#{unique_suffix}.yml") do
          message = /FACET_CONFIG_FILE is set but the file does not exist: '\/no\/such\/facet-config-.*\.yml'/
          expect_raises(Exception, message) { Facet::Config.load }
        end
      end
    end

    describe "DomainsConfig" do
      it "defaults to all domains enabled when neither included nor excluded is set" do
        cfg = build_config(
          domains: Config::DomainsConfig.new,
        )
        cfg.domain_enabled?("hr").should be_true
        cfg.domain_enabled?("crm").should be_true
        cfg.domain_enabled?("core").should be_true
      end

      it "enables only included domains when included is non-empty" do
        cfg = build_config(
          domains: Config::DomainsConfig.new(included: ["hr", "crm"]),
        )
        cfg.domain_enabled?("hr").should be_true
        cfg.domain_enabled?("crm").should be_true
        cfg.domain_enabled?("analytics").should be_false
        cfg.domain_enabled?("core").should be_false
      end

      it "disables only excluded domains when excluded is non-empty" do
        cfg = build_config(
          domains: Config::DomainsConfig.new(excluded: ["analytics"]),
        )
        cfg.domain_enabled?("hr").should be_true
        cfg.domain_enabled?("crm").should be_true
        cfg.domain_enabled?("core").should be_true
        cfg.domain_enabled?("analytics").should be_false
      end

      it "raises when both included and excluded are non-empty" do
        expect_raises(Exception, /mutually exclusive/) do
          build_config(
            domains: Config::DomainsConfig.new(included: ["hr"], excluded: ["analytics"]),
          )
        end
      end

      it "does not raise when both are empty" do
        cfg = build_config(
          domains: Config::DomainsConfig.new(included: [] of String, excluded: [] of String),
        )
        cfg.domain_enabled?("hr").should be_true
      end

      it "enables all domains when domains section is absent in YAML" do
        Config.reset!
        cfg = Config.instance
        cfg.domain_enabled?("hr").should be_true
        cfg.domain_enabled?("core").should be_true
      end
    end

    describe "MFAConfig" do
      it "defaults enforcement to preferred" do
        cfg = Config.from_yaml_node(build_mfa_config_yaml(nil))
        cfg.iam.mfa.enforcement.should eq("preferred")
        cfg.iam.mfa.enforcement_always?.should be_false
      end

      it "accepts the always enforcement mode" do
        cfg = Config.from_yaml_node(build_mfa_config_yaml("always"))
        cfg.iam.mfa.enforcement.should eq("always")
        cfg.iam.mfa.enforcement_always?.should be_true
      end

      it "accepts an explicit preferred enforcement mode" do
        cfg = Config.from_yaml_node(build_mfa_config_yaml("preferred"))
        cfg.iam.mfa.enforcement.should eq("preferred")
      end

      it "raises on an invalid enforcement value (fail closed)" do
        expect_raises(ArgumentError, /enforcement/) do
          Config.from_yaml_node(build_mfa_config_yaml("sometimes"))
        end
      end
    end

    describe "IAMConfig.secure_cookies" do
      it "defaults to secure cookies when the key is absent" do
        cfg = Config.from_yaml_node(build_iam_config_yaml("iam: {}"))
        cfg.iam.secure_cookies.should be_true
      end

      it "honors an explicit secure_cookies: false" do
        # The docker e2e stacks set this key; a loader that collapsed `false`
        # into `true` made the YAML key a lie (see e2e-harness plan, D2).
        cfg = Config.from_yaml_node(build_iam_config_yaml("iam:\n  secure_cookies: false"))
        cfg.iam.secure_cookies.should be_false
      end

      it "honors an explicit secure_cookies: true" do
        cfg = Config.from_yaml_node(build_iam_config_yaml("iam:\n  secure_cookies: true"))
        cfg.iam.secure_cookies.should be_true
      end
    end

    describe "MFAConfig.totp.enabled" do
      it "defaults TOTP to enabled when the key is absent" do
        cfg = Config.from_yaml_node(build_iam_config_yaml("iam: {}"))
        cfg.iam.mfa.totp.enabled.should be_true
      end

      it "honors an explicit totp.enabled: false" do
        cfg = Config.from_yaml_node(
          build_iam_config_yaml("iam:\n  mfa:\n    totp:\n      enabled: false")
        )
        cfg.iam.mfa.totp.enabled.should be_false
      end

      it "honors an explicit totp.enabled: true" do
        cfg = Config.from_yaml_node(
          build_iam_config_yaml("iam:\n  mfa:\n    totp:\n      enabled: true")
        )
        cfg.iam.mfa.totp.enabled.should be_true
      end
    end

    describe "AuthConfig" do
      it "defaults the auth mode to hybrid when the section is absent" do
        cfg = Config.from_yaml_node(build_iam_config_yaml("iam: {}"))
        cfg.iam.auth.mode.should eq("hybrid")
      end

      it "accepts the oidc_only mode" do
        cfg = Config.from_yaml_node(build_iam_config_yaml("iam:\n  auth:\n    mode: oidc_only"))
        cfg.iam.auth.mode.should eq("oidc_only")
      end

      it "raises on an invalid auth mode (fail closed, like enforcement)" do
        expect_raises(ArgumentError, /mode/) do
          Config.from_yaml_node(build_iam_config_yaml("iam:\n  auth:\n    mode: passwords_only"))
        end
      end
    end

    describe "LocalizationConfig" do
      it "defaults to UTC and en" do
        cfg = Config.from_yaml_node(build_yaml_config(""))
        cfg.localization.default_timezone.should eq("UTC")
        cfg.localization.default_language.should eq("en")
      end

      it "accepts explicit values" do
        cfg = Config.from_yaml_node(build_yaml_config("localization:\n  default_timezone: Europe/Paris\n  default_language: en"))
        cfg.localization.default_timezone.should eq("Europe/Paris")
        cfg.localization.default_language.should eq("en")
      end

      it "raises on a timezone the runtime cannot load" do
        expect_raises(ArgumentError, /IANA timezone/) do
          Config.from_yaml_node(build_yaml_config("localization:\n  default_timezone: Bogus/Nowhere"))
        end
      end

      it "raises on a language outside the allowlist" do
        expect_raises(ArgumentError, /default_language/) do
          Config.from_yaml_node(build_yaml_config("localization:\n  default_language: xx"))
        end
      end
    end

    describe "#scheme_base_url" do
      it "returns a scheme-bearing host verbatim (https)" do
        # The dev Caddy form: `https://localhost:3443`. The pre-fix
        # `IAM::Routes` code would have produced `https://https://localhost:3443`
        # from this value; `scheme_base_url` must preserve it unchanged.
        cfg = build_config(
          host: "https://localhost:3443",
        )
        cfg.scheme_base_url.should eq("https://localhost:3443")
      end

      it "returns a scheme-bearing host verbatim (http)" do
        cfg = build_config(
          host: "http://localhost:3000",
        )
        cfg.scheme_base_url.should eq("http://localhost:3000")
      end

      it "prepends https to a scheme-less host" do
        # The test-config form: `localhost:3000` — the accessor prepends the
        # scheme.
        cfg = build_config(
          host: "localhost:3000",
        )
        cfg.scheme_base_url.should eq("https://localhost:3000")
      end

      it "prepends https to a host with no port" do
        cfg = build_config(
          host: "app.example.com",
        )
        cfg.scheme_base_url.should eq("https://app.example.com")
      end
    end

    describe "DatabaseConfig" do
      it "defaults to no timeout when the database section is absent" do
        cfg = Config.from_yaml_node(build_database_config_yaml)
        cfg.database.statement_timeout_ms.should be_nil
      end

      it "loads statement_timeout_ms from the database section" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          database:
            statement_timeout_ms: 5000
          YAML
        ))
        cfg.database.statement_timeout_ms.should eq(5000)
      end

      it "treats an explicit null statement_timeout_ms as absent" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          database:
            statement_timeout_ms: null
          YAML
        ))
        cfg.database.statement_timeout_ms.should be_nil
      end

      it "rejects a negative statement_timeout_ms" do
        expect_raises(ArgumentError, /statement_timeout_ms/) do
          Config.from_yaml_node(build_database_config_yaml(<<-YAML
            database:
              statement_timeout_ms: -100
            YAML
          ))
        end
      end

      describe "cluster" do
        it "defaults to nil (back-compat single pool) when the section is absent" do
          cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
            database:
              statement_timeout_ms: 5000
            YAML
          ))
          cfg.database.cluster.should be_nil
        end

        it "parses the grammar with sizing and a replica" do
          cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
            database:
              cluster:
                databases:
                  main:
                    url: "postgres://db1:5432/facet"
                    initial_pool_size: 2
                    max_pool_size: 20
                    checkout_timeout_s: 5.0
                    replica:
                      url: "postgres://replica:5432/facet"
                      max_pool_size: 30
                    resources: ["*", "core", "iam", "$artifacts"]
                  hr_crm:
                    url: "postgres://db2:5432/facet"
                    resources: [hr, crm]
                  bulk_pool:
                    url: "postgres://db2:5432/facet"
                    max_pool_size: 8
                    resources: ["$bulk"]
            YAML
          ))
          cluster = cfg.database.cluster.not_nil!
          cluster.databases.size.should eq(3)

          main = cluster.databases[0]
          main.name.should eq("main")
          main.url.should eq("postgres://db1:5432/facet")
          main.resources.should eq(["*", "core", "iam", "$artifacts"])
          main.initial_pool_size.should eq(2)
          main.max_pool_size.should eq(20)
          main.checkout_timeout_s.should eq(5.0)
          replica = main.replica.not_nil!
          replica.url.should eq("postgres://replica:5432/facet")
          replica.max_pool_size.should eq(30)

          hr_crm = cluster.databases[1]
          hr_crm.resources.should eq(["hr", "crm"])
          hr_crm.replica.should be_nil

          bulk = cluster.databases[2]
          bulk.max_pool_size.should eq(8)
          bulk.resources.should eq(["$bulk"])
        end

        it "accepts a bare integer for checkout_timeout_s" do
          cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
            database:
              cluster:
                databases:
                  main:
                    url: "postgres://db1:5432/facet"
                    checkout_timeout_s: 2
                    resources: ["*"]
            YAML
          ))
          cfg.database.cluster.not_nil!.databases[0].checkout_timeout_s.should eq(2.0)
        end

        it "rejects a cluster with no '*' entry" do
          expect_raises(ArgumentError, /'\*'/) do
            Config.from_yaml_node(build_database_config_yaml(<<-YAML
              database:
                cluster:
                  databases:
                    main:
                      url: "postgres://db1:5432/facet"
                      resources: [core]
              YAML
            ))
          end
        end

        it "rejects a cluster with several '*' entries" do
          expect_raises(ArgumentError, /'\*'/) do
            Config.from_yaml_node(build_database_config_yaml(<<-YAML
              database:
                cluster:
                  databases:
                    main:
                      url: "postgres://db1:5432/facet"
                      resources: ["*"]
                    other:
                      url: "postgres://db2:5432/facet"
                      resources: ["*"]
              YAML
            ))
          end
        end

        it "rejects a resource claimed by two entries" do
          expect_raises(ArgumentError, /resource 'hr' appears in both/) do
            Config.from_yaml_node(build_database_config_yaml(<<-YAML
              database:
                cluster:
                  databases:
                    main:
                      url: "postgres://db1:5432/facet"
                      resources: ["*", hr]
                    other:
                      url: "postgres://db2:5432/facet"
                      resources: [hr]
              YAML
            ))
          end
        end

        it "rejects an entry without a url" do
          expect_raises(ArgumentError, /url is required/) do
            Config.from_yaml_node(build_database_config_yaml(<<-YAML
              database:
                cluster:
                  databases:
                    main:
                      resources: ["*"]
              YAML
            ))
          end
        end

        it "rejects an entry without resources" do
          expect_raises(ArgumentError, /resources/) do
            Config.from_yaml_node(build_database_config_yaml(<<-YAML
              database:
                cluster:
                  databases:
                    main:
                      url: "postgres://db1:5432/facet"
              YAML
            ))
          end
        end

        it "rejects a replica without a url" do
          expect_raises(ArgumentError, /replica.url is required/) do
            Config.from_yaml_node(build_database_config_yaml(<<-YAML
              database:
                cluster:
                  databases:
                    main:
                      url: "postgres://db1:5432/facet"
                      resources: ["*"]
                      replica:
                        max_pool_size: 4
              YAML
            ))
          end
        end

        it "rejects an empty resource string" do
          expect_raises(ArgumentError, /non-empty strings/) do
            Config.from_yaml_node(build_database_config_yaml(<<-YAML
              database:
                cluster:
                  databases:
                    main:
                      url: "postgres://db1:5432/facet"
                      resources: [""]
              YAML
            ))
          end
        end
      end
    end

    describe "CacheConfig" do
      it "defaults to a 300 s bound when the cache section is absent" do
        cfg = Config.from_yaml_node(build_database_config_yaml)
        cfg.cache.staleness_ttl_s.should eq(300)
      end

      it "loads staleness_ttl_s from the cache section" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          cache:
            staleness_ttl_s: 60
          YAML
        ))
        cfg.cache.staleness_ttl_s.should eq(60)
      end

      it "honors an explicit 0 as disabled" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          cache:
            staleness_ttl_s: 0
          YAML
        ))
        cfg.cache.staleness_ttl_s.should eq(0)
      end

      it "rejects a negative staleness_ttl_s (fail loud, not silently disabled)" do
        expect_raises(ArgumentError, /staleness_ttl_s/) do
          Config.from_yaml_node(build_database_config_yaml(<<-YAML
            cache:
              staleness_ttl_s: -30
            YAML
          ))
        end
      end
    end

    describe "LogsConfig" do
      it "defaults when the logs section is absent" do
        cfg = Config.from_yaml_node(build_database_config_yaml)
        cfg.logs.format.should eq("text")
        cfg.logs.level.should eq("info")
      end

      it "loads format and level from the logs section" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          logs:
            format: json
            level: warn
          YAML
        ))
        cfg.logs.format.should eq("json")
        cfg.logs.level.should eq("warn")
      end

      it "rejects an unknown format" do
        expect_raises(ArgumentError, /logs.format/) do
          Config.from_yaml_node(build_database_config_yaml(<<-YAML
            logs:
              format: xml
            YAML
          ))
        end
      end

      it "rejects an unknown level" do
        expect_raises(ArgumentError, /logs.level/) do
          Config.from_yaml_node(build_database_config_yaml(<<-YAML
            logs:
              level: loudest
            YAML
          ))
        end
      end
    end

    describe "trusted_proxies" do
      it "defaults to an empty list when the key is absent" do
        cfg = Config.from_yaml_node(build_database_config_yaml)
        cfg.trusted_proxies.should eq([] of String)
      end

      it "loads the proxy list" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          trusted_proxies:
            - "127.0.0.1"
            - "::1"
          YAML
        ))
        cfg.trusted_proxies.should eq(["127.0.0.1", "::1"])
      end

      it "rejects an entry that trims to nothing (fail loud)" do
        expect_raises(ArgumentError, /trusted_proxies/) do
          Config.from_yaml_node(build_database_config_yaml(<<-YAML
            trusted_proxies:
              - "127.0.0.1"
              - "   "
            YAML
          ))
        end
      end
    end

    describe "MutationsConfig" do
      it "defaults when the mutations section is absent" do
        cfg = Config.from_yaml_node(build_database_config_yaml)
        cfg.mutations.retention_days.should eq(180)
        cfg.mutations.retention_overrides.should be_empty
        cfg.mutations.compaction_cron.should eq("45 3 * * *")
        cfg.mutations.coalesce_window_minutes.should eq(3)
      end

      it "loads the mutations section" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          mutations:
            retention_days: 365
            retention_overrides:
              hr.Employee: 730
            compaction_cron: "30 2 * * *"
            coalesce_window_minutes: 10
          YAML
        ))
        cfg.mutations.retention_days.should eq(365)
        cfg.mutations.retention_overrides.should eq({"hr.Employee" => 730})
        cfg.mutations.compaction_cron.should eq("30 2 * * *")
        cfg.mutations.coalesce_window_minutes.should eq(10)
      end

      it "accepts coalesce_window_minutes = 0 (disables coalescing)" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          mutations:
            coalesce_window_minutes: 0
          YAML
        ))
        cfg.mutations.coalesce_window_minutes.should eq(0)
      end

      it "resolves the retention window per doctype (override wins, absent key falls back)" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          mutations:
            retention_days: 180
            retention_overrides:
              hr.Employee: 365
          YAML
        ))
        cfg.retention_days_for("hr", "Employee").should eq(365)
        cfg.retention_days_for("crm", "Company").should eq(180)
      end

      it "accepts retention_days = 0 (keep forever — compaction off)" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          mutations:
            retention_days: 0
          YAML
        ))
        cfg.mutations.retention_days.should eq(0)
      end

      it "rejects a negative retention_days" do
        expect_raises(ArgumentError, /retention_days/) do
          Config.from_yaml_node(build_database_config_yaml(<<-YAML
            mutations:
              retention_days: -1
            YAML
          ))
        end
      end

      it "rejects a negative coalesce_window_minutes" do
        expect_raises(ArgumentError, /coalesce_window_minutes/) do
          Config.from_yaml_node(build_database_config_yaml(<<-YAML
            mutations:
              coalesce_window_minutes: -1
            YAML
          ))
        end
      end

      it "rejects a non-positive retention override" do
        expect_raises(ArgumentError, /retention_overrides/) do
          Config.from_yaml_node(build_database_config_yaml(<<-YAML
            mutations:
              retention_overrides:
                hr.Employee: 0
            YAML
          ))
        end
      end
    end

    describe "MailConfig" do
      it "defaults the adapter to dev and the override to false when the mail section is absent" do
        cfg = Config.from_yaml_node(build_mail_config_yaml)
        cfg.mail.adapter.should eq("dev")
        cfg.mail.allow_dev_adapter_in_production.should be_false
      end

      it "parses the allow_dev_adapter_in_production override" do
        cfg = Config.from_yaml_node(build_mail_config_yaml(<<-YAML
          mail:
            adapter: dev
            allow_dev_adapter_in_production: true
          YAML
        ))
        cfg.mail.adapter.should eq("dev")
        cfg.mail.allow_dev_adapter_in_production.should be_true
      end
    end

    describe "mail dev-adapter gate" do
      it "raises when production boots with the default dev adapter (mail section absent)" do
        with_production_env do
          expect_raises(Exception, /allow_dev_adapter_in_production/) do
            Config.from_yaml_node(build_mail_config_yaml)
          end
        end
      end

      it "raises when production boots with an explicit dev adapter" do
        with_production_env do
          expect_raises(Exception, /not allowed in APP_ENV=production/) do
            Config.from_yaml_node(build_mail_config_yaml(<<-YAML
              mail:
                adapter: dev
              YAML
            ))
          end
        end
      end

      it "boots when allow_dev_adapter_in_production is set (air-gapped override)" do
        with_production_env do
          cfg = Config.from_yaml_node(build_mail_config_yaml(<<-YAML
            mail:
              adapter: dev
              allow_dev_adapter_in_production: true
            YAML
          ))
          cfg.mail.adapter.should eq("dev")
        end
      end

      it "boots with the smtp adapter" do
        with_production_env do
          cfg = Config.from_yaml_node(build_mail_config_yaml(<<-YAML
            mail:
              adapter: smtp
              smtp:
                host: smtp.example.test
                port: 587
            YAML
          ))
          cfg.mail.adapter.should eq("smtp")
        end
      end

      it "does not emit the dev-adapter warning during the config parse" do
        Config.reset_dev_adapter_warning!
        Log.capture("facet.config") do |logs|
          Config.from_yaml_node(build_mail_config_yaml)
          Config.from_yaml_node(build_mail_config_yaml)
          logs.empty
        end
      end

      it "emits the dev-adapter warning once per process from the boot call" do
        Config.reset_dev_adapter_warning!
        Log.capture("facet.config") do |logs|
          Config.warn_dev_mail_adapter_once
          logs.check(:warn, /Mail adapter is 'dev'/)
          Config.warn_dev_mail_adapter_once
          logs.empty
        end
      end
    end

    # An empty YAML section parses to a node that wraps nil; a key read on
    # such a node raises a raw YAML error. Every section loader must treat a
    # present-but-empty section like an absent one, so a fully commented-out
    # section body never crashes the config load.
    describe "empty optional sections" do
      it "treats an empty jobs: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("jobs:"))
        cfg.jobs.retention_days.should eq(30)
        cfg.jobs.enabled.should be_true
      end

      it "treats an empty webhook: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("webhook:"))
        cfg.webhook.timeout_s.should eq(10)
        cfg.webhook.reconcile_window_hours.should eq(24)
      end

      it "treats an empty dev: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("dev:"))
        cfg.dev.domain_watch.should be_nil
      end

      it "treats an empty import_export: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("import_export:"))
        cfg.import_export.wait_poll_ms.should eq(500)
        cfg.import_export.wait_timeout_s.should eq(30)
      end

      it "treats an empty mutations: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("mutations:"))
        cfg.mutations.retention_days.should eq(180)
        cfg.mutations.coalesce_window_minutes.should eq(3)
      end

      it "treats an empty iam: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("iam:"))
        cfg.iam.secure_cookies.should be_true
        cfg.iam.auth.mode.should eq("hybrid")
      end

      it "treats an empty mail: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("mail:"))
        cfg.mail.adapter.should eq("dev")
      end

      it "treats an empty lua: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("lua:"))
        cfg.lua.instruction_limit.should eq(1_000_000)
        cfg.lua.memory_limit_mb.should eq(32)
        cfg.lua.time_limit_s.should eq(0.5)
      end

      it "treats an empty hooks: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("hooks:"))
        cfg.hooks.lease_ttl_s.should eq(600)
      end

      it "treats an empty mcp: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("mcp:"))
        cfg.mcp.max_concurrency_per_sid.should eq(4)
      end

      it "treats an empty sidecar: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("sidecar:"))
        cfg.sidecar.reconcile_cron.should eq("0 */1 * * *")
      end

      it "treats an empty tombstone: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("tombstone:"))
        cfg.tombstone.content_retention_days.should eq(30)
      end

      it "treats an empty cache: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("cache:"))
        cfg.cache.staleness_ttl_s.should eq(300)
      end

      it "treats an empty websocket: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("websocket:"))
        cfg.websocket.collection.max_subscribers_per_doctype.should eq(32)
      end

      it "treats an empty logs: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("logs:"))
        cfg.logs.format.should eq("text")
        cfg.logs.level.should eq("info")
      end

      it "treats an empty localization: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("localization:"))
        cfg.localization.default_timezone.should eq("UTC")
        cfg.localization.default_language.should eq("en")
      end

      it "treats an empty domains: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("domains:"))
        cfg.domain_enabled?("hr").should be_true
      end

      it "treats an empty database: section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("database:"))
        cfg.database.statement_timeout_ms.should be_nil
        cfg.database.cluster.should be_nil
      end
    end

    describe "empty sub-sections" do
      it "treats empty iam sub-sections like absent ones" do
        cfg = Config.from_yaml_node(build_yaml_config("iam:\n  jwt:\n  mfa:\n  auth:"))
        cfg.iam.jwt.access_token_ttl.should eq(900)
        cfg.iam.mfa.enforcement.should eq("preferred")
        cfg.iam.auth.mode.should eq("hybrid")
      end

      it "treats an empty iam.mfa.totp sub-section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("iam:\n  mfa:\n    totp:"))
        cfg.iam.mfa.totp.enabled.should be_true
      end

      it "treats an empty mail.smtp sub-section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("mail:\n  smtp:"))
        cfg.mail.smtp.host.should eq("localhost")
        cfg.mail.smtp.port.should eq(587)
      end

      it "treats an empty dev.domain_watch sub-section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("dev:\n  domain_watch:"))
        cfg.dev.domain_watch.should be_nil
      end

      it "treats an empty event.stream sub-section like an absent one" do
        cfg = Config.from_yaml_node(YAML.parse(
          <<-YAML
            event:
              url: "redis://localhost:6379/1"
              stream:
            artifact_base_url: "http://localhost:3001"
            artifact_grant_secret: "test-grant-secret"
            artifact:
              storage:
                type: filesystem
                directory: tmp/uploads/test/store
            secrets:
              master_key: "#{TEST_MASTER_KEY}"
          YAML
        ))
        cfg.event.stream.max_block_time.should eq(2.0)
        cfg.event.stream.min_block_time.should eq(0.1)
      end

      it "treats an empty websocket.collection sub-section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("websocket:\n  collection:"))
        cfg.websocket.collection.max_subscribers_per_doctype.should eq(32)
      end

      it "treats an empty database.cluster sub-section like an absent one" do
        cfg = Config.from_yaml_node(build_yaml_config("database:\n  cluster:"))
        cfg.database.cluster.should be_nil
      end

      it "treats an empty cluster replica entry like an absent one" do
        cfg = Config.from_yaml_node(build_database_config_yaml(<<-YAML
          database:
            cluster:
              databases:
                main:
                  url: "postgres://localhost:5432/facet"
                  resources: ["*"]
                  replica:
          YAML
        ))
        cluster = cfg.database.cluster.not_nil!
        cluster.databases.size.should eq(1)
        cluster.databases.first.replica.should be_nil
      end
    end

    describe "empty required sections" do
      it "raises the missing-event message, not a raw YAML error, when the event section is empty" do
        expect_raises(Exception, /Missing 'event' key/) do
          Config.from_yaml_node(YAML.parse(
            <<-YAML
              event:
              artifact_base_url: "http://localhost:3001"
              artifact_grant_secret: "test-grant-secret"
              artifact:
                storage:
                  type: filesystem
                  directory: tmp/uploads/test/store
              secrets:
                master_key: "#{TEST_MASTER_KEY}"
            YAML
          ))
        end
      end

      it "raises the missing-storage message, not a raw YAML error, when the artifact section is empty" do
        expect_raises(Exception, /Missing required config key 'artifact\.storage'/) do
          Config.from_yaml_node(YAML.parse(
            <<-YAML
              event:
                url: "redis://localhost:6379/1"
              artifact_base_url: "http://localhost:3001"
              artifact_grant_secret: "test-grant-secret"
              artifact:
              secrets:
                master_key: "#{TEST_MASTER_KEY}"
            YAML
          ))
        end
      end
    end
  end

  describe Secrets::Config do
    it "loads a full secrets section" do
      cfg = Secrets::Config.from_yaml(YAML.parse(
        <<-YAML
          master_key: "#{TEST_MASTER_KEY}"
          bcrypt_cost: 10
          staging_ttl_seconds: 600
          prune_after_days: 7
          prune_cron: "0 3 * * *"
        YAML
      ))
      cfg.bcrypt_cost.should eq(10)
      cfg.staging_ttl_seconds.should eq(600)
      cfg.prune_after_days.should eq(7)
      cfg.prune_cron.should eq("0 3 * * *")
      cfg.key_bytes.size.should eq(32)
    end

    it "applies defaults for absent keys" do
      cfg = Secrets::Config.from_yaml(YAML.parse(
        <<-YAML
          master_key: "#{TEST_MASTER_KEY}"
        YAML
      ))
      cfg.bcrypt_cost.should eq(12)
      cfg.staging_ttl_seconds.should eq(900)
      cfg.prune_after_days.should eq(30)
      cfg.prune_cron.should eq("45 4 * * *")
    end

    it "fails closed on an absent section" do
      expect_raises(ArgumentError, /master_key/) do
        Secrets::Config.from_yaml(nil).validate!
      end
    end

    it "raises on a missing master_key" do
      expect_raises(ArgumentError, /master_key/) do
        Secrets::Config.from_yaml(YAML.parse(
          <<-YAML
            bcrypt_cost: 10
          YAML
        )).validate!
      end
    end

    it "raises on a master_key that decodes to fewer than 32 bytes" do
      expect_raises(ArgumentError, /at least/) do
        Secrets::Config.from_yaml(YAML.parse(
          <<-YAML
            master_key: "c2hvcnQ="
          YAML
        )).validate!
      end
    end

    it "raises on a non-base64 master_key" do
      expect_raises(ArgumentError, /base64/) do
        Secrets::Config.from_yaml(YAML.parse(
          <<-YAML
            master_key: "not valid base64 !!!"
          YAML
        )).validate!
      end
    end

    it "fails the config-file load when the secrets section is absent" do
      expect_raises(ArgumentError, /secrets\.master_key/) do
        Config.from_yaml_node(YAML.parse(
          <<-YAML
            event:
              url: "redis://localhost:6379/1"
            artifact_base_url: "http://localhost:3001"
            artifact_grant_secret: "test-grant-secret"
            artifact:
              storage:
                type: filesystem
                directory: tmp/uploads/test/store
          YAML
        ))
      end
    end

    it "parses a section with only some keys (defaults keep the rest)" do
      cfg = Secrets::Config.from_yaml(YAML.parse(
        <<-YAML
          bcrypt_cost: 4
        YAML
      ))
      cfg.bcrypt_cost.should eq(4)
      cfg.staging_ttl_seconds.should eq(900)
      cfg.prune_cron.should eq("45 4 * * *")
    end

    it "treats an empty section like an absent one (fail closed)" do
      # A present-but-empty `secrets:` node wraps nil, so the parser must
      # short-circuit before any key read on that node.
      raw = YAML.parse("secrets:")
      expect_raises(ArgumentError, /secrets\.master_key/) do
        Secrets::Config.from_yaml(raw["secrets"]?).validate!
      end
    end

    it "loads through the config-file path when master_key is present" do
      cfg = Config.from_yaml_node(build_yaml_config(""))
      cfg.secrets.master_key.should eq(TEST_MASTER_KEY)
      cfg.secrets.bcrypt_cost.should eq(12)
    end

    it "fails the config-file load with the master_key message when the secrets section is empty" do
      expect_raises(ArgumentError, /secrets\.master_key/) do
        Config.from_yaml_node(YAML.parse(
          <<-YAML
            event:
              url: "redis://localhost:6379/1"
            artifact_base_url: "http://localhost:3001"
            artifact_grant_secret: "test-grant-secret"
            artifact:
              storage:
                type: filesystem
                directory: tmp/uploads/test/store
            secrets:
          YAML
        ))
      end
    end

    it "rejects an unknown key id" do
      cfg = Secrets::Config.new(master_key: TEST_MASTER_KEY)
      expect_raises(ArgumentError, /key id/) do
        cfg.key_bytes("rotated-2026")
      end
    end
  end
end

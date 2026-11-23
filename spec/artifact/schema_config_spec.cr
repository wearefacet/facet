# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/config"
require "yaml"

# Step 1 of the artifact system: schema + config.
#
# Files covered:
#   - db/migrations/0003_artifacts.sql (the four-table data model)
#   - src/config.cr (base_url, artifact_base_url, artifact_grant_secret,
#     artifact_grant_secret_previous, ArtifactConfig)
#   - src/artifact/config.cr (Facet::Artifact::Config)
#
# The migration is applied by `spec_helper.cr`'s `Spec.before_suite` hook
# during template-database provisioning — if `0003_artifacts.sql` had a
# syntax error or a bad FK, the suite would not start. The first spec
# below verifies the resulting shape explicitly so a regression surfaces
# as a single failing example rather than a worker-spawn failure.

describe Facet::Artifact do
  describe "schema (migration 0003_artifacts.sql)" do
    it "creates the artifacts table with the documented columns" do
      Facet::Database.with_db do |db|
        cols = db.query_all(<<-SQL, as: {String, String})
          SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_name = 'artifacts'
          ORDER BY ordinal_position
        SQL

        col_map = {} of String => String
        cols.each { |name, type| col_map[name] = type }

        col_map.keys.should contain("id")
        col_map.keys.should contain("filename")
        col_map.keys.should contain("mime_type")
        col_map.keys.should contain("size")
        col_map.keys.should contain("signature_sha256")
        col_map.keys.should contain("path")
        col_map.keys.should contain("deleted_at")
        col_map.keys.should contain("created_at")

        # No access-bearing columns leak onto artifacts (the transversal
        # invariant): the table has no domain / owner / publicity / creator.
        col_map.keys.should_not contain("domain")
        col_map.keys.should_not contain("created_by")
        col_map.keys.should_not contain("owner")
        col_map.keys.should_not contain("public")

        # The legacy shape (content bytea / location text / meta jsonb)
        # must not be present — replacing 0007 dropped them.
        col_map.keys.should_not contain("content")
        col_map.keys.should_not contain("location")
        col_map.keys.should_not contain("meta")

        # size is bigint so multi-GB uploads fit.
        col_map["size"].should eq("bigint")
        col_map["signature_sha256"].should eq("text")
      end
    end

    it "creates the artifact_owners table with the provenance columns" do
      Facet::Database.with_db do |db|
        cols = db.query_all(<<-SQL, as: {String, String})
          SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_name = 'artifact_owners'
          ORDER BY ordinal_position
        SQL

        names = cols.map(&.[0])
        names.should contain("id")
        names.should contain("artifact_id")
        names.should contain("domain")
        names.should contain("doc_type")
        names.should contain("doc_id")
        names.should contain("field_path")
        names.should contain("view_tag")
        names.should contain("created_by")
        names.should contain("created_at")
      end
    end

    it "creates the artifact_grants table with epoch and kind" do
      Facet::Database.with_db do |db|
        cols = db.query_all(<<-SQL, as: {String, String})
          SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_name = 'artifact_grants'
          ORDER BY ordinal_position
        SQL

        names = cols.map(&.[0])
        names.should contain("id")
        names.should contain("artifact_id")
        names.should contain("owner_id")
        names.should contain("kind")
        names.should contain("expires_at")
        names.should contain("epoch")
        names.should contain("created_by")
        names.should contain("created_at")
      end
    end

    it "creates the artifact_references table with the prune-bookkeeping columns" do
      Facet::Database.with_db do |db|
        cols = db.query_all(<<-SQL, as: {String, String})
          SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_name = 'artifact_references'
          ORDER BY ordinal_position
        SQL

        names = cols.map(&.[0])
        names.should contain("artifact_id")
        names.should contain("domain")
        names.should contain("resource_id")
        names.should contain("resource_field")
        names.should contain("last_reference_at")
      end
    end

    it "deploys the partial dedup index on signature_sha256 where deleted_at is null" do
      Facet::Database.with_db do |db|
        # pg_indexes gives the partial predicate verbatim in `indexdef`.
        index_def = db.query_one(<<-SQL, as: String)
          SELECT indexdef
          FROM pg_indexes
          WHERE tablename = 'artifacts'
            AND indexname = 'artifacts_dedup_idx'
        SQL

        # The index must be on signature_sha256 and partial on deleted_at IS NULL
        # — a plain UNIQUE index would break the dedup-when-unreadable flow.
        index_def.should contain("signature_sha256")
        index_def.should contain("deleted_at IS NULL")
        # Not unique — the upload flow stores a second copy when the
        # candidate isn't readable.
        index_def.downcase.should_not contain("unique")
      end
    end

    it "covers cascading deletes from artifacts down to grants and references" do
      Facet::Database.with_db do |db|
        # Defensive cleanup: the global per-example TRUNCATE in spec_helper.cr
        # does not cover the artifact tables (they are not part of the
        # document/projection lifecycle). Start from a known-empty state so
        # this spec is order-independent and self-cleaning on success.
        db.exec("TRUNCATE artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")

        Facet::Database.with_transaction(db) do |tx|
          # Insert an artifact, an owner, a grant, and a reference.
          tx.exec(<<-SQL, "01H8XK8P7Z5Q0Y3W2V1U0T0S0R", "hash-1")
            INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path)
            VALUES ($1, 'a.txt', 'text/plain', 4, $2, 'hash-1/01H8XK8P7Z5Q0Y3W2V1U0T0S0R')
          SQL

          tx.exec(<<-SQL, "owner-1", "01H8XK8P7Z5Q0Y3W2V1U0T0S0R")
            INSERT INTO artifact_owners (id, artifact_id, domain, doc_type, doc_id, field_path, created_by)
            VALUES ($1, $2, 'core', 'Asset', '01H8XK8P7Z5Q0Y3W2V1U0T0S0R0', 'cover', 'sys')
          SQL

          tx.exec(<<-SQL, "grant-1", "01H8XK8P7Z5Q0Y3W2V1U0T0S0R", "owner-1")
            INSERT INTO artifact_grants (id, artifact_id, owner_id, kind, created_by)
            VALUES ($1, $2, $3, 'ephemeral', 'sys')
          SQL

          tx.exec(<<-SQL, "01H8XK8P7Z5Q0Y3W2V1U0T0S0R")
            INSERT INTO artifact_references (artifact_id, domain, resource_id, resource_field)
            VALUES ($1, 'core', '01H8XK8P7Z5Q0Y3W2V1U0T0S0R0', 'cover')
          SQL

          # Cascading delete from artifacts sweeps all three dependents.
          tx.exec("DELETE FROM artifacts WHERE id = $1", "01H8XK8P7Z5Q0Y3W2V1U0T0S0R")

          count = tx.query_one("SELECT COUNT(*) FROM artifact_owners WHERE id = $1", "owner-1", as: Int64)
          count.should eq(0)

          count = tx.query_one("SELECT COUNT(*) FROM artifact_grants WHERE id = $1", "grant-1", as: Int64)
          count.should eq(0)

          count = tx.query_one("SELECT COUNT(*) FROM artifact_references WHERE artifact_id = $1",
            "01H8XK8P7Z5Q0Y3W2V1U0T0S0R", as: Int64)
          count.should eq(0)
        end
      end
    end
  end

  describe Facet::Artifact::Config do
    it "fails loud when the artifact: section is absent" do
      expect_raises(Exception, /Missing required config key 'artifact.storage'/) do
        Facet::Artifact::Config.from_yaml(nil)
      end
    end

    it "applies the documented defaults to the optional knobs when only storage is set" do
      raw = YAML.parse(<<-YAML
        storage:
          type: filesystem
          directory: tmp/uploads/test/store
        YAML
      )

      cfg = Facet::Artifact::Config.from_yaml(raw)
      cfg.storage.type.should eq("filesystem")
      cfg.storage.directory.should eq("tmp/uploads/test/store")
      cfg.prune_after_days.should eq(30)
      cfg.grant_ttl_seconds.should eq(3600)
      cfg.grant_ttl_media_seconds.should eq(21_600)
      cfg.max_upload_bytes.should eq(52_428_800_i64)
      cfg.grant_prune_days.should eq(7)
      cfg.grant_prune_cron.should eq("0 5 * * *")
    end

    it "overrides individual knobs from the artifact: section" do
      raw = YAML.parse(<<-YAML
        prune_after_days: 7
        grant_ttl_seconds: 30
        grant_ttl_media_seconds: 3600
        max_upload_bytes: 1024
        grant_prune_days: 14
        grant_prune_cron: "30 5 * * *"
        storage:
          type: filesystem
          directory: tmp/uploads/test/store
        YAML
      )

      cfg = Facet::Artifact::Config.from_yaml(raw)
      cfg.prune_after_days.should eq(7)
      cfg.grant_ttl_seconds.should eq(30)
      cfg.grant_ttl_media_seconds.should eq(3600)
      cfg.max_upload_bytes.should eq(1024_i64)
      cfg.grant_prune_days.should eq(14)
      cfg.grant_prune_cron.should eq("30 5 * * *")
    end

    it "fails loud when the storage entry is absent from the section" do
      raw = YAML.parse(<<-YAML
        prune_after_days: 7
        YAML
      )

      expect_raises(Exception, /Missing required config key 'artifact.storage'/) do
        Facet::Artifact::Config.from_yaml(raw)
      end
    end

    it "defaults the storage type to filesystem" do
      raw = YAML.parse(<<-YAML
        storage:
          directory: tmp/uploads/test/store
        YAML
      )

      cfg = Facet::Artifact::Config.from_yaml(raw)
      cfg.storage.type.should eq("filesystem")
    end

    it "fails loud on an unknown storage type" do
      raw = YAML.parse(<<-YAML
        storage:
          type: gcs
          bucket: facet-artifacts
        YAML
      )

      expect_raises(Exception, /Unknown artifact.storage.type 'gcs'/) do
        Facet::Artifact::Config.from_yaml(raw)
      end
    end

    it "fails loud when an s3 storage lacks bucket, region, or credentials" do
      ENV.delete("S3_ACCESS_KEY_ID")
      ENV.delete("S3_SECRET_ACCESS_KEY")

      raw = YAML.parse(<<-YAML
        storage:
          type: s3
          bucket: facet-artifacts
        YAML
      )

      expect_raises(Exception, /missing required fields: region, access_key_id, secret_access_key/) do
        Facet::Artifact::Config.from_yaml(raw)
      end
    end

    it "fills the s3 credentials from the env fallback" do
      ENV["S3_ACCESS_KEY_ID"] = "key"
      ENV["S3_SECRET_ACCESS_KEY"] = "secret"
      begin
        raw = YAML.parse(<<-YAML
          storage:
            type: s3
            bucket: facet-artifacts
            region: eu-west-1
          YAML
        )

        cfg = Facet::Artifact::Config.from_yaml(raw)
        cfg.storage.access_key_id.should eq("key")
        cfg.storage.secret_access_key.should eq("secret")
      ensure
        ENV.delete("S3_ACCESS_KEY_ID")
        ENV.delete("S3_SECRET_ACCESS_KEY")
      end
    end
  end

  describe "Facet::Config artifact fields" do
    it "loads artifact_base_url, the grant secret, and the_previous rotation key from YAML" do
      Facet::Config.reset!
      cfg = Facet::Config.instance

      # See config.test.yml.
      cfg.artifact_base_url.should eq("http://localhost:3001")
      cfg.base_url.should eq("http://localhost:3000")
      cfg.artifact_grant_secret.should eq("test-grant-secret-fixed")
      # Not declared in config.test.yml — rotation is opt-in.
      cfg.artifact_grant_secret_previous.should be_nil

      # Defaults flow through from Artifact::Config.
      cfg.artifact.prune_after_days.should eq(30)
      cfg.artifact.grant_ttl_seconds.should eq(3600)
      cfg.artifact.grant_ttl_media_seconds.should eq(21_600)
      cfg.artifact.max_upload_bytes.should eq(52_428_800_i64)
      cfg.artifact.grant_prune_days.should eq(7)
      cfg.artifact.grant_prune_cron.should eq("0 5 * * *")
    end

    it "fails loud when artifact_base_url is missing" do
      raw = YAML.parse(<<-YAML)
        host: "localhost:3000"
        artifact_grant_secret: "s"
        artifact:
          storage:
            type: filesystem
            directory: tmp/uploads/test/store
        event:
          url: "redis://localhost:6379/0"
        secrets:
          master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
      YAML

      expect_raises(Exception, /Missing required config key 'artifact_base_url'/) do
        Facet::Config.from_yaml_node(raw)
      end
    end

    it "fails loud when artifact_grant_secret is missing or empty" do
      raw = YAML.parse(<<-YAML)
        host: "localhost:3000"
        artifact_base_url: "http://localhost:3001"
        artifact:
          storage:
            type: filesystem
            directory: tmp/uploads/test/store
        event:
          url: "redis://localhost:6379/0"
        secrets:
          master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
      YAML

      expect_raises(Exception, /Missing required config key 'artifact_grant_secret'/) do
        Facet::Config.from_yaml_node(raw)
      end
    end

    it "fails loud when the artifact: section is absent" do
      raw = YAML.parse(<<-YAML)
        host: "localhost:3000"
        artifact_base_url: "http://localhost:3001"
        artifact_grant_secret: "s"
        event:
          url: "redis://localhost:6379/0"
        secrets:
          master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
      YAML

      expect_raises(Exception, /Missing required config key 'artifact.storage'/) do
        Facet::Config.from_yaml_node(raw)
      end
    end

    it "reads the artifact grant secret from ARTIFACT_GRANT_SECRET when YAML omits it" do
      ENV["ARTIFACT_GRANT_SECRET"] = "env-secret-override"

      begin
        raw = YAML.parse(<<-YAML)
          host: "localhost:3000"
          artifact_base_url: "http://localhost:3001"
          artifact:
            storage:
              type: filesystem
              directory: tmp/uploads/test/store
          event:
            url: "redis://localhost:6379/0"
          secrets:
            master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
        YAML

        cfg = Facet::Config.from_yaml_node(raw)
        cfg.artifact_grant_secret.should eq("env-secret-override")
      ensure
        ENV.delete("ARTIFACT_GRANT_SECRET")
      end
    end

    it "loads artifact_grant_secret_previous for two-key rotation" do
      raw = YAML.parse(<<-YAML)
        host: "localhost:3000"
        artifact_base_url: "http://localhost:3001"
        artifact_grant_secret: "current"
        artifact_grant_secret_previous: "previous"
        artifact:
          storage:
            type: filesystem
            directory: tmp/uploads/test/store
        event:
          url: "redis://localhost:6379/0"
        secrets:
          master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
      YAML

      cfg = Facet::Config.from_yaml_node(raw)
      cfg.artifact_grant_secret.should eq("current")
      cfg.artifact_grant_secret_previous.should eq("previous")
    end

    it "falls back to host for base_url when base_url is absent" do
      raw = YAML.parse(<<-YAML)
        host: "example.test:8080"
        artifact_base_url: "http://cdn.example.test"
        artifact_grant_secret: "s"
        artifact:
          storage:
            type: filesystem
            directory: tmp/uploads/test/store
        event:
          url: "redis://localhost:6379/0"
        secrets:
          master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
      YAML

      cfg = Facet::Config.from_yaml_node(raw)
      cfg.base_url.should eq("example.test:8080")
      cfg.host.should eq("example.test:8080")
    end
  end

  describe "Facet::Config.load with !env" do
    it "expands !env scalars when loading from a file" do
      ENV["FACET_TEST_GRANT_SECRET"] = "env-injected-secret"
      dir = File.join(Dir.tempdir, "facet-config-env-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)
      begin
        path = File.join(dir, "config.test.yml")
        File.write(path, <<-YAML
          host: "localhost:3000"
          artifact_base_url: "http://localhost:3001"
          artifact_grant_secret: !env FACET_TEST_GRANT_SECRET
          artifact:
            storage:
              type: filesystem
              directory: tmp/uploads/test/store
          event:
            url: "redis://localhost:6379/0"
          secrets:
            master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
          YAML
        )

        cfg = Facet::Config.load(path)
        cfg.artifact_grant_secret.should eq("env-injected-secret")
      ensure
        ENV.delete("FACET_TEST_GRANT_SECRET")
        FileUtils.rm_r(dir) if Dir.exists?(dir)
      end
    end

    it "raises at load when the referenced variable is not set" do
      ENV.delete("FACET_TEST_GRANT_SECRET_MISSING")
      dir = File.join(Dir.tempdir, "facet-config-env-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)
      begin
        path = File.join(dir, "config.test.yml")
        File.write(path, <<-YAML
          host: "localhost:3000"
          artifact_base_url: "http://localhost:3001"
          artifact_grant_secret: !env FACET_TEST_GRANT_SECRET_MISSING
          artifact:
            storage:
              type: filesystem
              directory: tmp/uploads/test/store
          event:
            url: "redis://localhost:6379/0"
          YAML
        )

        expect_raises(Facet::Util::YamlInclude::IncludeError, /is not set in the environment/) do
          Facet::Config.load(path)
        end
      ensure
        FileUtils.rm_r(dir) if Dir.exists?(dir)
      end
    end
  end
end

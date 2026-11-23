# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Artifact
    # Tunable knobs for the artifact subsystem.
    #
    # Loaded from the `artifact:` section of `config.{env}.yml`. The
    # section is required — `from_yaml` fails loud at config load when
    # `artifact.storage` is absent or malformed, so a misconfigured
    # deployment stops at boot instead of returning 500 on the first
    # upload. The other fields keep safe defaults. See
    # `doc/backend/artifact.md`.
    struct Config
      # Object storage for artifact bytes. Required in the YAML —
      # `from_yaml` fails loud at load when the `storage:` entry is
      # absent, empty, or invalid. Direct construction (specs, tooling)
      # defaults to the dev filesystem store.
      getter storage : Storage

      # Eligibility window for prune. An artifact whose `artifact_references`
      # rows are all older than this many days is treated as unreferenced
      # by the references clause of the prune query.
      getter prune_after_days : Int32

      # Signed-URL TTL for non-media types (documents, images). Long
      # enough to outlive a normal "render page → click link" round-trip
      # on human-paced browsing.
      getter grant_ttl_seconds : Int32

      # Signed-URL TTL for `audio/*` and `video/*` artifacts — long enough
      # that a seek mid-playback doesn't hit an expired URL.
      getter grant_ttl_media_seconds : Int32

      # Hard cap on a single upload's body size, in bytes. Enforced before
      # the request touches disk so an oversized upload returns `413`
      # without spooling a tempfile.
      getter max_upload_bytes : Int64

      # TTL of a signed upload capability (`Artifact::UploadGrants`) — the
      # one-time URL an MCP agent POSTs its multipart body to. Short by
      # design: a mint-to-upload gap is seconds, not hours.
      getter upload_grant_ttl_seconds : Int32

      # Retention window for expired `ephemeral` grant rows, in days. A row
      # leaves `artifact_grants` once it expired at least this long ago;
      # `0` keeps every expired row forever — the prune skips. Resolved
      # per pass through `core.SystemSettings` (`artifact.grant_prune_days`).
      getter grant_prune_days : Int32

      # Schedule for the expired-grant prune task (`Cron::ArtifactGrantPrune`).
      getter grant_prune_cron : String

      def initialize(
        @storage : Storage = Storage.new,
        @prune_after_days : Int32 = 30,
        @grant_ttl_seconds : Int32 = 3600,
        @grant_ttl_media_seconds : Int32 = 21_600,
        @max_upload_bytes : Int64 = 52_428_800_i64,
        @upload_grant_ttl_seconds : Int32 = 300,
        @grant_prune_days : Int32 = 7,
        @grant_prune_cron : String = "0 5 * * *",
      )
      end

      # One object-storage backend for artifact bytes. `type` is
      # `"filesystem"` or `"s3"`; the S3 fields only apply to `"s3"`.
      record Storage,
        type : String = "filesystem",
        directory : String = "tmp/uploads/dev",
        bucket : String? = nil,
        region : String? = nil,
        access_key_id : String? = nil,
        secret_access_key : String? = nil,
        endpoint : String? = nil,
        public : Bool = false

      # Parses the `artifact:` section of `config.{env}.yml`. Absent knobs
      # keep the defaults. Fails loud when `artifact.storage` is absent or
      # malformed — the error must surface at config load, not at the
      # first upload.
      def self.from_yaml(raw : YAML::Any?) : self
        # A present-but-empty section wraps nil — normalize it, so the
        # required-storage check raises its own message, not a raw YAML
        # error.
        raw = nil if raw && raw.raw.nil?
        new(
          storage: read_storage(raw.try(&.["storage"]?)),
          prune_after_days: read_int(raw.try(&.["prune_after_days"]?), 30),
          grant_ttl_seconds: read_int(raw.try(&.["grant_ttl_seconds"]?), 3600),
          grant_ttl_media_seconds: read_int(raw.try(&.["grant_ttl_media_seconds"]?), 21_600),
          max_upload_bytes: read_int64(raw.try(&.["max_upload_bytes"]?), 52_428_800),
          upload_grant_ttl_seconds: read_int(raw.try(&.["upload_grant_ttl_seconds"]?), 300),
          grant_prune_days: read_int(raw.try(&.["grant_prune_days"]?), 7),
          grant_prune_cron: raw.try(&.["grant_prune_cron"]?).try(&.as_s) || "0 5 * * *",
        )
      end

      # Parses `artifact.storage`. The entry is required — an absent,
      # empty, or non-mapping entry raises, so a deployment missing the
      # section stops at config load instead of returning 500 on the
      # first upload. S3 credentials fall back to the env vars so secrets
      # can stay out of the checked-in YAML. The `as_h?` guard must run
      # before the key reads: `YAML::Any#[]?` raises on a scalar receiver.
      private def self.read_storage(value : YAML::Any?) : Storage
        unless value.try(&.as_h?)
          raise "Missing required config key 'artifact.storage'. " \
                "Add a 'storage:' entry under 'artifact:' in config.{env}.yml."
        end

        storage = Storage.new(
          type: value.try(&.["type"]?).try(&.as_s) || "filesystem",
          directory: value.try(&.["directory"]?).try(&.as_s) || "tmp/uploads/dev",
          bucket: value.try(&.["bucket"]?).try(&.as_s),
          region: value.try(&.["region"]?).try(&.as_s),
          access_key_id: value.try(&.["access_key_id"]?).try(&.as_s) || ENV["S3_ACCESS_KEY_ID"]?,
          secret_access_key: value.try(&.["secret_access_key"]?).try(&.as_s) || ENV["S3_SECRET_ACCESS_KEY"]?,
          endpoint: value.try(&.["endpoint"]?).try(&.as_s) || ENV["S3_ENDPOINT"]?,
          public: value.try(&.["public"]?).try(&.as_bool) || false
        )
        validate_storage(storage)
        storage
      end

      # Validates the parsed storage entry. The uploader would otherwise
      # discover an unknown type or an incomplete S3 entry lazily — a 500
      # on the first upload. Same fail-closed contract as the other
      # required config keys.
      private def self.validate_storage(storage : Storage) : Nil
        case storage.type
        when "filesystem"
          if storage.directory.empty?
            raise "artifact.storage.directory must not be empty. " \
                  "Set a directory path under 'artifact.storage' in config.{env}.yml, " \
                  "or remove the key to use the default."
          end
        when "s3"
          missing = [] of String
          missing << "bucket" unless storage.bucket
          missing << "region" unless storage.region
          missing << "access_key_id" unless storage.access_key_id
          missing << "secret_access_key" unless storage.secret_access_key
          unless missing.empty?
            raise "artifact.storage.type 's3' is missing required fields: #{missing.join(", ")}. " \
                  "Set 'bucket' and 'region' under 'artifact.storage' in config.{env}.yml; " \
                  "the credentials may also come from the S3_ACCESS_KEY_ID / " \
                  "S3_SECRET_ACCESS_KEY env vars."
          end
        else
          raise "Unknown artifact.storage.type '#{storage.type}' — " \
                "expected 'filesystem' or 's3'."
        end
      end

      private def self.read_int(value : YAML::Any?, default : Int32) : Int32
        return default if value.nil? || value.raw.nil?
        value.as_i
      end

      private def self.read_int64(value : YAML::Any?, default : Int) : Int64
        return default.to_i64 if value.nil? || value.raw.nil?
        value.as_i.to_i64
      end
    end
  end
end

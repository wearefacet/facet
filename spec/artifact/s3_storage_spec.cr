# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/rbac"
require "awscr-s3"
require "digest/sha256"

# Step 3b of the artifact system: the S3 storage branches of the uploader.
#
# Files covered:
#   - src/artifact/uploader.cr — `open` / `put_object` dispatch on the
#     configured storage; `open_s3` / `put_s3` talk to awscr directly.
#
# The shard's `Shrine::Storage::S3#open` (0.6.5) returns the response
# wrapper's inspect string positioned at EOF, and its `#upload` sends a
# `String` body whose `Content-Length` (character count) breaks on binary
# payloads with valid multi-byte UTF-8 sequences. Facet therefore bypasses
# both methods, and these specs pin the replacement against a fake S3
# HTTP endpoint: byte-exact round trips, a rewound seekable IO on open,
# and `ObjectNotFound` on a missing key.

DOMAIN_S3 = "arts3"

STORAGE_KEY_S3 = "s3spec"

# A minimal S3-compatible endpoint. Stores objects keyed by request path
# (`bucket/key`), answers the PUT/GET/HEAD/DELETE verbs awscr uses, and
# emits the S3 error XML for a missing key so awscr raises `NoSuchKey`.
private class FakeS3
  getter bucket : String = "facet-spec"
  getter port : Int32

  @objects = Hash(String, Bytes).new
  @server : HTTP::Server

  def initialize
    @server = HTTP::Server.new do |ctx|
      key = ctx.request.path.lchop('/').lchop("#{bucket}/")
      case ctx.request.method
      when "PUT"
        io = IO::Memory.new
        IO.copy(ctx.request.body.not_nil!, io)
        @objects[key] = io.to_slice
        ctx.response.status_code = 200
        ctx.response.headers["ETag"] = %("#{Digest::SHA1.hexdigest(io.to_slice)}")
      when "GET"
        if obj = @objects[key]?
          ctx.response.status_code = 200
          ctx.response.headers["Content-Type"] = "application/octet-stream"
          ctx.response.write(obj)
        else
          ctx.response.status_code = 404
          ctx.response.content_type = "application/xml"
          ctx.response.print(<<-XML
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>
            XML
          )
        end
      when "HEAD"
        ctx.response.status_code = @objects.has_key?(key) ? 200 : 404
      when "DELETE"
        @objects.delete(key)
        ctx.response.status_code = 204
      end
    end
    @port = @server.bind_unused_port("127.0.0.1").port
    spawn { @server.listen }
  end

  def storage : Shrine::Storage::S3
    Shrine::Storage::S3.new(
      bucket: bucket,
      client: Awscr::S3::Client.new(
        "us-east-1", "key", "secret",
        endpoint: "http://127.0.0.1:#{port}",
      ),
    )
  end

  def stored_bytes(key : String) : Bytes?
    @objects[key]?
  end

  def close : Nil
    @server.close
  end
end

# Binary payload whose byte stream contains valid multi-byte UTF-8
# sequences — the exact class of content that broke the shard's String
# upload (`String#size` < `bytesize`).
private def binary_bytes(size : Int32 = 5000) : Bytes
  bytes = Bytes.new(size)
  size.times { |i| bytes[i] = (i % 251).to_u8 }
  300.times do |i|
    bytes[(i * 17) % size] = 0xC3_u8
    bytes[(i * 17 + 1) % size] = 0xA9_u8
  end
  bytes
end

# Registers the fake-bucket storage under a dedicated key so the global
# `store` binding — and every other spec reading it — stays untouched.
private def with_s3_storage(fake : FakeS3, &)
  Shrine.configure { |c| c.storages[STORAGE_KEY_S3] = fake.storage }
  yield
ensure
  Shrine.configure { |c| c.storages[STORAGE_KEY_S3]? && c.storages.delete(STORAGE_KEY_S3) }
end

private def truncate_artifact_tables_s3
  with_db &.exec("TRUNCATE artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

private def setup_upload_target_s3(db, doctype = "Asset", field = "file")
  ensure_domain(db, DOMAIN_S3)
  file_type = Facet::Doctype::FieldType.parse("file")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: DOMAIN_S3,
    fields: {
      field => Facet::Doctype::FieldDefinition.new(type: file_type),
    } of String => Facet::Doctype::FieldDefinition,
  )
  res = Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  )
  res.should be_a(Facet::Document::Create::Result)

  doc_res = Facet::Document::Create.call(
    db, DOMAIN_S3, doctype, %({}), Facet::RBAC::AuthContext.system,
  )
  doc_res.should be_a(Facet::Document::Create::Result)
  {doctype, doc_res.as(Facet::Document::Create::Result).projection.id}
end

describe Facet::Artifact::Uploader do
  before_each { truncate_artifact_tables_s3 }

  describe "S3 storage" do
    it "open returns a rewound, seekable IO holding the exact object bytes" do
      fake = FakeS3.new
      begin
        with_s3_storage(fake) do
          bytes = binary_bytes
          key = "#{Digest::SHA256.hexdigest(bytes)}/01TESTARTIFACT"
          fake.storage.client.put_object(fake.bucket, key, bytes)

          io = Facet::Artifact::Uploader.open(key, storage_key: STORAGE_KEY_S3)
          mem = io.should be_a(IO::Memory)
          # The pre-fix bug: the returned IO sat at EOF with the response
          # wrapper's inspect string in the buffer. Position must be 0 and
          # size must match the object.
          mem.pos.should eq(0)
          mem.size.should eq(bytes.size)

          served = mem.gets_to_end
          served.bytesize.should eq(bytes.size)
          served.to_slice.should eq(bytes)
        end
      ensure
        fake.close
      end
    end

    it "open raises ObjectNotFound when the key is missing" do
      fake = FakeS3.new
      begin
        with_s3_storage(fake) do
          expect_raises(Facet::Artifact::Uploader::ObjectNotFound) do
            Facet::Artifact::Uploader.open("missing/01TESTKEY", storage_key: STORAGE_KEY_S3)
          end
        end
      ensure
        fake.close
      end
    end

    it "upload stores byte-exact bytes for binary payloads and the object reads back" do
      fake = FakeS3.new
      begin
        with_s3_storage(fake) do
          with_db do |db|
            doctype, doc_id = setup_upload_target_s3(db)
            bytes = binary_bytes

            result = Facet::Artifact::Uploader.upload(
              db, IO::Memory.new(bytes), "photo.bin",
              Facet::RBAC::AuthContext.system,
              DOMAIN_S3, doctype, doc_id, "file", nil,
              storage_key: STORAGE_KEY_S3,
            )
            result.should be_a(Facet::Artifact::Uploader::Result)
            res = result.as(Facet::Artifact::Uploader::Result)
            res.object_uploaded.should be_true
            res.size.should eq(bytes.size)

            # The bucket holds exactly the uploaded bytes.
            stored = fake.stored_bytes(res.path)
            stored.should_not be_nil
            stored.not_nil!.should eq(bytes)

            # The owner row is bound to the document.
            owners = Facet::Artifact::Store.find_owner_rows(db, res.artifact_id)
            owners.size.should eq(1)
            owners[0].doc_id.should eq(doc_id)

            # The serve path reads the object back byte-exact.
            io = Facet::Artifact::Uploader.open(res.path, storage_key: STORAGE_KEY_S3)
            io.gets_to_end.to_slice.should eq(bytes)
          end
        end
      ensure
        fake.close
      end
    end
  end
end

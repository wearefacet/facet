# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/index"
require "../../src/index/retry_cli"
require "../../src/doctype"
require "../../src/mutation/client"

# Registers a one-field doctype definition as a `core.DocType` projection
# so `recheck_indexes` classifies the row's index as still desired. The
# stored definition round-trips through JSON the same way `Domain::Copy`
# persists it.
private def register_single_field_definition(db, domain : String, doctype : String, field : String)
  definition = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: domain,
    fields: {
      field => Facet::Doctype::FieldDefinition.new(
        type: Facet::Doctype::FieldType.parse("string"),
        filters: [Facet::Doctype::FilterCapability::Equality],
      ),
    }
  )

  Facet::Database.with_transaction(db) do |txn|
    Facet::Mutation::Client.create(
      txn, "core", "DocType",
      doc_id: "#{domain}.#{doctype}",
      content: definition.to_json,
      actioner_id: "spec",
    )
  end
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{doctype}")
end

# Captures everything the block prints on STDOUT through a temp-file
# redirect. Mirrors `silence_stdout` in `spec/support/io_helper.cr` but
# reads the bytes back instead of discarding them. Kept at file scope: a
# `def` cannot be declared inside the spec DSL's describe blocks.
private def capture_stdout(& : -> Nil) : String
  STDOUT.flush
  saved_fd = LibC.dup(STDOUT.fd)
  raise IO::Error.new("dup(STDOUT.fd) failed") if saved_fd < 0

  tmp = File.tempfile("retry_cli_stdout")
  LibC.dup2(tmp.fd, STDOUT.fd)
  begin
    yield
    STDOUT.flush
  ensure
    LibC.dup2(saved_fd, STDOUT.fd)
    LibC.close(saved_fd)
  end
  content = File.read(tmp.path)
  tmp.delete
  content
end

describe Facet::Index::RetryCLI do
  # The suite runs `Index::Manager` in synchronous mode, so the retried
  # CREATE runs inline (no `CONCURRENTLY`, no background fiber) — the
  # leftover pre-drop and the status flow stay identical.
  it "drops a leftover index and rebuilds it when retrying an error row" do
    with_db do |db|
      domain = "spec_index_retry"
      doctype = "RetryDoc"
      field = "email"

      register_single_field_definition(db, domain, doctype, field)

      index_name = Facet::Index::Naming.index_name(domain, doctype, field, "btree")

      # Simulate the failed-attempt state: the physical index is on disk
      # (as a failed `CREATE INDEX CONCURRENTLY` leaves it) and the
      # tracking row is in `error` status.
      db.exec(Facet::Index::Naming.create_index_sql(domain, doctype, field, "btree", concurrent: false))
      db.exec(
        "INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name, status) " \
        "VALUES ($1, $2, $3, $4, $5, 'error')",
        domain, doctype, field, "btree", index_name
      )

      # `pg_relation_filenode` changes only when the index object is
      # actually dropped and rebuilt. A no-op `CREATE INDEX IF NOT EXISTS`
      # against the leftover would keep the same filenode — the
      # silent-broken-index outcome the in-gate pre-drop prevents.
      filenode_before = db.query_one(
        "SELECT pg_relation_filenode($1::regclass)::text",
        index_name,
        as: String
      )

      Facet::Index::RetryCLI.retry_all(db)

      status = db.query_one(
        "SELECT status FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )
      status.should eq("active")

      filenode_after = db.query_one(
        "SELECT pg_relation_filenode($1::regclass)::text",
        index_name,
        as: String
      )
      filenode_before.should_not be_empty
      filenode_after.should_not be_empty
      filenode_after.should_not eq(filenode_before)

      valid = db.query_one(
        "SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1",
        index_name,
        as: Bool
      )
      valid.should be_true
    end
  end

  # B-46 casualty shape: a DDL fiber died before completing its batch and
  # left the tracking row `pending` with no INVALID index behind. The row
  # is stale (the fiber never touched it again), so the retry picks it up
  # and it converges to `active` — the documented recovery path fires.
  it "retries a stale pending row left by a dead DDL fiber" do
    with_db do |db|
      domain = "spec_index_retry"
      doctype = "PendingDoc"
      field = "email"

      register_single_field_definition(db, domain, doctype, field)

      index_name = Facet::Index::Naming.index_name(domain, doctype, field, "btree")
      db.exec(
        "INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name, status) " \
        "VALUES ($1, $2, $3, $4, $5, 'pending')",
        domain, doctype, field, "btree", index_name
      )
      # Age the row past `PENDING_STALE_MINUTES` — a dead fiber never
      # touches its rows again, so `updated_at` stays at insert time.
      db.exec(
        "UPDATE doctype_indexes SET updated_at = now() - interval '1 hour' WHERE index_name = $1",
        index_name
      )

      Facet::Index::RetryCLI.retry_all(db)

      status = db.query_one(
        "SELECT status FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )
      status.should eq("active")

      valid = db.query_one(
        "SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1",
        index_name,
        as: Bool
      )
      valid.should be_true
    end
  end

  # A fresh `pending` row belongs to a live DDL fiber in the running
  # server — retrying it would race the in-flight CREATE. The staleness
  # guard must leave it alone.
  it "leaves a fresh pending row alone" do
    with_db do |db|
      domain = "spec_index_retry"
      doctype = "FreshPendingDoc"
      field = "email"

      register_single_field_definition(db, domain, doctype, field)

      index_name = Facet::Index::Naming.index_name(domain, doctype, field, "btree")
      db.exec(
        "INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name, status) " \
        "VALUES ($1, $2, $3, $4, $5, 'pending')",
        domain, doctype, field, "btree", index_name
      )

      Facet::Index::RetryCLI.retry_all(db)

      status = db.query_one(
        "SELECT status FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )
      status.should eq("pending")
    end
  end

  # B-50 regression pins: the domain/doctype filters narrow the retryable
  # set, they never widen it. Before the fix the filter conditions were
  # joined with OR onto the status predicate, so a filter became an
  # alternative way for a row to qualify — healthy `active` indexes were
  # rebuilt and `error` rows of other domains were picked up.
  it "does not select an active row that the filter names" do
    with_db do |db|
      domain = "spec_index_retry"
      doctype = "FilteredActiveDoc"
      field = "email"

      # The definition is registered so a wrong selection would run the
      # real DDL (not a skip) — the pin must fail on the old OR-shaped
      # query, not pass vacuously.
      register_single_field_definition(db, domain, doctype, field)

      index_name = Facet::Index::Naming.index_name(domain, doctype, field, "btree")
      db.exec(
        "INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name, status) " \
        "VALUES ($1, $2, $3, $4, $5, 'active')",
        domain, doctype, field, "btree", index_name
      )
      # Age the row past the stale-pending window — only the status can
      # rule it out. A stale `active` row is still healthy.
      db.exec(
        "UPDATE doctype_indexes SET updated_at = now() - interval '1 hour' WHERE index_name = $1",
        index_name
      )
      updated_at_before = db.query_one(
        "SELECT updated_at::text FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )

      Facet::Index::RetryCLI.retry_all(db, domain_filter: domain, doctype_filter: doctype)

      status = db.query_one(
        "SELECT status FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )
      status.should eq("active")

      # Untouched means untouched: no status flip, no `updated_at` bump,
      # no physical index built.
      updated_at_after = db.query_one(
        "SELECT updated_at::text FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )
      updated_at_after.should eq(updated_at_before)

      exists = db.query_one(
        "SELECT to_regclass($1) IS NOT NULL",
        index_name,
        as: Bool
      )
      exists.should be_false
    end
  end

  it "does not select an error row outside the filter's domain" do
    with_db do |db|
      domain = "spec_index_retry"
      other_domain = "spec_index_retry_other"
      doctype = "FilteredErrorDoc"
      field = "email"

      register_single_field_definition(db, other_domain, doctype, field)

      index_name = Facet::Index::Naming.index_name(other_domain, doctype, field, "btree")
      db.exec(
        "INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name, status) " \
        "VALUES ($1, $2, $3, $4, $5, 'error')",
        other_domain, doctype, field, "btree", index_name
      )
      updated_at_before = db.query_one(
        "SELECT updated_at::text FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )

      Facet::Index::RetryCLI.retry_all(db, domain_filter: domain, doctype_filter: doctype)

      status = db.query_one(
        "SELECT status FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )
      status.should eq("error")

      updated_at_after = db.query_one(
        "SELECT updated_at::text FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )
      updated_at_after.should eq(updated_at_before)

      exists = db.query_one(
        "SELECT to_regclass($1) IS NOT NULL",
        index_name,
        as: Bool
      )
      exists.should be_false
    end
  end

  it "selects and rebuilds an error row that the filter names" do
    with_db do |db|
      domain = "spec_index_retry"
      doctype = "FilteredErrorDoc"
      field = "email"

      register_single_field_definition(db, domain, doctype, field)

      index_name = Facet::Index::Naming.index_name(domain, doctype, field, "btree")
      db.exec(
        "INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name, status) " \
        "VALUES ($1, $2, $3, $4, $5, 'error')",
        domain, doctype, field, "btree", index_name
      )

      Facet::Index::RetryCLI.retry_all(db, domain_filter: domain, doctype_filter: doctype)

      status = db.query_one(
        "SELECT status FROM doctype_indexes WHERE index_name = $1",
        index_name,
        as: String
      )
      status.should eq("active")

      exists = db.query_one(
        "SELECT to_regclass($1) IS NOT NULL",
        index_name,
        as: Bool
      )
      exists.should be_true
    end
  end

  # F09-02: the shared teardown runs `retry_all` after seeding and
  # transfer commands. With `quiet: true` an empty retryable set must
  # print nothing — the command never touches an index, so an index line
  # is noise. The explicit `facet index:retry` keeps its line (next
  # example). The table is cleared first so the empty-set branch is
  # deterministic; every example in this file registers its own rows.
  it "prints nothing on an empty retryable set when quiet is set" do
    with_db do |db|
      db.exec("DELETE FROM doctype_indexes")

      output = capture_stdout do
        Facet::Index::RetryCLI.retry_all(db, quiet: true)
      end
      output.should be_empty
    end
  end

  it "prints the empty-set line without the quiet flag" do
    with_db do |db|
      db.exec("DELETE FROM doctype_indexes")

      output = capture_stdout do
        Facet::Index::RetryCLI.retry_all(db)
      end
      output.should contain("No failed or stale-pending indexes found.")
    end
  end
end

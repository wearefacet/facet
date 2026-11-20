-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- UP

-- ---------------------------------------------------------------------------
-- replication_subscriptions
--
-- Maps source records to consumer records for cross-domain field replication.
-- Maintained transactionally with consumer-side events:
--   - Consumer record created with a non-null ref, or ref field set/changed
--     → upsert subscription rows (and remove rows for previous ref on change)
--   - Consumer record deleted, or ref unset → remove subscription rows
--
-- This table is the subscription index — it enables O(1) lookup of which
-- consumer records need updating when a producer record changes, avoiding
-- full scans.
-- ---------------------------------------------------------------------------
CREATE TABLE replication_subscriptions (
    source_domain    varchar(128) NOT NULL,
    source_doc_type  varchar(128) NOT NULL,
    source_id        text         NOT NULL,

    consumer_domain    varchar(128) NOT NULL,
    consumer_doc_type  varchar(128) NOT NULL,
    consumer_id        text         NOT NULL,

    consumer_field  text NOT NULL,   -- field name on the consuming doctype
    source_field    text NOT NULL,   -- field name on the source doctype

    created_at  timestamp NOT NULL DEFAULT now(),

    PRIMARY KEY (source_domain, source_doc_type, source_id,
                 consumer_domain, consumer_doc_type, consumer_id,
                 consumer_field)
);

-- Index for reverse lookup: find subscriptions by consumer record
CREATE INDEX idx_replication_subscriptions_consumer
    ON replication_subscriptions (consumer_domain, consumer_doc_type, consumer_id);

-- Index for source lookup: find subscriptions by source record
CREATE INDEX idx_replication_subscriptions_source
    ON replication_subscriptions (source_domain, source_doc_type, source_id);

-- DOWN

DROP INDEX IF EXISTS idx_replication_subscriptions_consumer;
DROP INDEX IF EXISTS idx_replication_subscriptions_source;
DROP TABLE IF EXISTS replication_subscriptions;

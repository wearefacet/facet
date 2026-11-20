-- SPDX-License-Identifier: BUSL-1.1
-- Copyright (c) 2026 Amplitude Solutions Ltd

-- UP

-- ---------------------------------------------------------------------------
-- sequence_identifiers
-- ---------------------------------------------------------------------------
-- Stores the last generated sequential identifier per doctype.
-- The `identifier` section of a DoctypeDefinition declares the template;
-- at document-creation time the system locks this row (via advisory lock)
-- and reads/writes `last_value` atomically.
CREATE TABLE sequence_identifiers (
    domain     varchar(128) NOT NULL,
    doc_type   varchar(128) NOT NULL,
    last_value text NOT NULL,
    PRIMARY KEY (domain, doc_type)
);

-- DOWN

DROP TABLE IF EXISTS sequence_identifiers;

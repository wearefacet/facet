# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Namespace root for the domain-grants concern.
#
# Domain grants are documents (`core.DomainGrant`) under the producer
# domain — the domain that gives the data and owns the consent. Each grant
# names one consumer domain and lists the resources (producer doctypes +
# field tags) the consumer may read. Grants confer read access only and
# must be activated before any gate honours them. Four gates enforce the
# model: the replication registry, the write-time pull, hook event
# delivery, and Lua cross-domain reads. See `doc/backend/domain-grants.md`.
module Facet
  module Grants
    Log = ::Log.for("facet.grants")

    # The `default` tag: the resolved label of an untagged producer field.
    # A grant resource entry naming `default` reaches every untagged field
    # of the entry's doctype.
    DEFAULT_TAG = "default"
  end
end

require "./grants/validator"
require "./grants/registry"
require "./grants/publish_tickets"
require "./grants/routes"

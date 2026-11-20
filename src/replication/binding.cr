# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Replication
    # A static description of one cross-domain replication edge.
    #
    # Built by `Replication::Registry` at startup and on each `core.DocType`
    # change. One `Binding` says: "documents in `consumer_domain.consumer_doctype`
    # carry a local reference field `ref_field` whose target is a document in
    # `source_doctype`; replicate the source's `source_field` into the local
    # `replica_field`; on source delete, apply `on_source_delete`."
    #
    # The binding is **consumer-centric** — it lives on the consumer side of
    # the edge. The registry groups bindings by **source doctype** for O(1)
    # lookup when a source mutation arrives.
    record Binding,
      consumer_domain : String,  # e.g. "hr"
      consumer_doctype : String, # "Employee"
      ref_field : String,        # local reference field name (the "via")
      replica_field : String,    # local replicated field name (F.name)
      source_doctype : String,   # qualified "identity.Person"
      source_field : String,     # "full_name"
      on_source_delete : String  # "keep" | "unset"
  end
end

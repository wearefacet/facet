# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Database
    # The `database.cluster:` config grammar (the segregation design, §4.1).
    #
    # These records are the parsed shape of the optional `database.cluster:`
    # section. `Facet::Config.load_database` parses and validates the YAML
    # into them (validation fails the load); `Database.init` turns them into
    # the route table and the pool map. They live in their own file so the
    # config side and the pool side share one definition without depending
    # on each other.
    #
    # A resource is a domain id (`hr`), a subsystem tag (`$artifacts` — the
    # `$` prefix is reserved; domain ids never start with `$`), or `*` — the
    # default for every resource listed nowhere. The mode never appears in
    # the config: routing is a function of the resource alone.
    record ClusterConfig,
      databases : Array(ClusterDatabase)

    # One physical database entry: its URL, optional pool sizing, optional
    # read-only pool, and the resources it holds.
    record ClusterDatabase,
      name : String,
      url : String,
      resources : Array(String),
      initial_pool_size : Int32? = nil,
      max_pool_size : Int32? = nil,
      checkout_timeout_s : Float64? = nil,
      replica : ClusterReplica? = nil

    # The read-only pool of an entry — a true replica when its URL differs,
    # or pool isolation at the same URL (the read-only enforcement hook,
    # not the host, refuses writes).
    record ClusterReplica,
      url : String,
      initial_pool_size : Int32? = nil,
      max_pool_size : Int32? = nil,
      checkout_timeout_s : Float64? = nil
  end
end

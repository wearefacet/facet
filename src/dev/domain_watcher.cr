# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "mutex"
require "yaml"
require "digest/sha256"
require "../database"
require "../config"
require "../event/publisher"
require "../domain/check"
require "../domain/scratch"
require "../domain/portable/import"
require "../domain/portable/service_error_format"
require "../doctype/reproject"
require "../doctype/structure"
require "../metrics"
require "../util/fiber_supervisor"
require "./check_report"

module Facet
  module Dev
    # Watches a dev folder tree and injects folder-authored domains into
    # the running system. The developer authors domains as files; the
    # watcher polls the folder and applies every change, so the design loop
    # never touches the editor UI, the API, or the AI builder.
    #
    # ## The watch root
    #
    # `config.dev.domain_watch.path` names the **watch root** — a parent
    # directory of domain bundles. Every immediate child directory that
    # contains a readable `bundle.yml` is a managed bundle; its
    # `source_domain` is the identity and names the target domain (no
    # prefix, no rename). Children are discovered on every poll, so a
    # bundle added while the server runs is picked up without a restart. A
    # child without `bundle.yml` is ignored. Two children naming the same
    # `source_domain` are ambiguous ownership: the alphabetically first
    # child syncs, and a warning names both directories every cycle until
    # the duplication is removed.
    #
    # ## Sync cycle (per changed child)
    #
    # 1. `Portable::Archive.read` the child directory.
    # 2. Capture the domain's pre-sync state (the parsed definition and the
    #    live document count of every doctype).
    # 3. Teardown + import inside ONE transaction. The teardown runs per
    #    the documents mode: `preserve` runs
    #    `Domain::Scratch.dispose_definitions!` (definitions only —
    #    documents, personal views, and artifact provenance survive);
    #    `discard` runs `Domain::Scratch.dispose!` (everything).
    # 4. Fresh `Portable::Import.call` — the whole bundle re-applies into
    #    the now-absent domain, joining the same transaction (its
    #    `ignore_if_set` wrapper). A failed import — a returned error or a
    #    raise — rolls the teardown back with it, so the domain keeps its
    #    previous state; the events the import enqueued are discarded with
    #    the rollback. On success the transaction commits once. The
    #    document replay is idempotent: rows that already exist are
    #    skipped, so `preserve` keeps app-created documents and `discard`
    #    reseeds from `documents/`. A doctype that left the bundle has its
    #    data tombstoned after the commit (the replay would otherwise
    #    re-create rows from a stale `documents/` tree) — a doctype that
    #    leaves the bundle takes its data with it.
    # 5. `Event::Publisher.flush` — a background task must flush itself
    #    (same rule as `Cron::SidecarReconcile`).
    # 6. Structure warnings: for every doctype whose fields changed in any
    #    data-shape way (additive included — `Doctype::Structure`
    #    `:field`-kind changes) or whose derived surface (`search` paths,
    #    `display_name` template) changed, while carrying live documents, a
    #    warning names the doctype and the kept document count.
    # 7. Post-sync diagnostics: `Domain::Check.call` runs for the synced
    #    domain and a one-line warning names the issue count and the first
    #    message (a clean domain logs nothing). In `preserve`, every warned
    #    doctype then runs `Doctype::Reproject`, so the kept rows' derived
    #    columns (`search` / `links` / `display_name`) match the new
    #    definitions. Diagnostics never fail the cycle — a failure is
    #    logged and skipped.
    # 8. A one-line summary names the domain and the import counters.
    #
    # Every mutation the sync writes carries the `system:import` actioner
    # id (`Portable::Import::ACTIONER_ID`), so the mutation log stays the
    # full history of the dev loop.
    #
    # ## Fingerprint + debounce
    #
    # Each child has its own fingerprint: the SHA-256 of the ordered
    # `(relative_path, mtime_unix_ms, size)` list of every file under the
    # child, recursed. A child cycles when its fingerprint differs from the
    # last attempted one **and** the same new fingerprint is observed on
    # two consecutive polls (the debounce — editors write in bursts and
    # save-often tooling emits several events per save). A failed cycle
    # still records the fingerprint: validation errors wait for the next
    # save instead of re-firing on every poll.
    #
    # ## Policy
    #
    # - **Dev only.** The boot code refuses to start the watcher when the
    #   resolved environment is `production`, even if the config section is
    #   present. The config line is the teardown consent for every domain
    #   the root's children name.
    # - **Nothing here deletes a live domain.** A removed bundle directory
    #   warns and keeps the domain's last synced state; a vanished watch
    #   root warns and skips polling. Only the `discard` documents mode or
    #   `db_reset` destroys data.
    # - **A failed sync keeps the domain's previous state.** The teardown
    #   and the import share one transaction, so a failed import rolls the
    #   teardown back with it — the domain stays live and unchanged.
    #   Sibling domains are unaffected — fault isolation is per child.
    # - **Replace warning.** The first teardown of a domain this process
    #   did not create warns distinctly (restarts included). The tracking
    #   is in-memory, so a restart may re-fire the warning once. Accepted
    #   for dev mode.
    class DomainWatcher
      Log = ::Log.for("facet.dev.domain_watcher")

      # The bundle-row failure prefix in `Import`'s error messages (see
      # `import_failure_doctypes`).
      private ROW_ERROR_PREFIX = "Bundle document '"

      # One managed child under the watch root. `path` is the directory;
      # `domain` is the bundle's `source_domain` (the target identity).
      private record Child,
        path : String,
        domain : String

      # One doctype's pre-sync state: the parsed definition (when the
      # stored row parses) and the count of live documents under the
      # doctype. Both feed the preserve-mode structure warnings.
      private record PreDoctype,
        definition : Doctype::DoctypeDefinition?,
        live_documents : Int64

      getter config : Facet::Config::DomainWatchConfig

      @wake : Channel(Nil)?

      # The boot guard: the watcher refuses to run when the resolved
      # environment is `production`, even if the config section is present.
      # The section lives in `config.dev.yml` only; this predicate makes the
      # refusal explicit and testable.
      def self.allowed?(app_env : String) : Bool
        app_env != "production"
      end

      def initialize(
        @config : Facet::Config::DomainWatchConfig,
        @clock : Proc(Time) = -> { Time.utc },
      )
        @mutex = Mutex.new
        @stopped = true
        # Child path → fingerprint observed on the previous poll (debounce).
        @observed = {} of String => String
        # Child path → fingerprint of the last sync attempt (success or
        # failure). A cycle only re-fires when this differs.
        @attempted = {} of String => String
        # Child path → source domain, for the removed-child warning.
        @child_domains = {} of String => String
        # Domains this watcher process created or already replaced. The
        # replace warning fires once per domain per process.
        @managed_domains = Set(String).new
      end

      # Returns `true` while the poll fibre is running.
      def running? : Bool
        @mutex.synchronize { !@stopped }
      end

      # Spawns the poll fibre. Idempotent: a no-op when already running.
      # The first tick runs the initial scan + sync, so bundles that exist
      # before the server boots are applied once the server is ready. The
      # loop runs under `Util::FiberSupervisor`: a raise that escapes the
      # loop body restarts it after a backoff instead of killing the
      # watcher silently.
      def start : Nil
        @mutex.synchronize do
          return unless @stopped
          @stopped = false
          @wake = Channel(Nil).new
        end
        Util::FiberSupervisor.supervise("Dev Domain Watcher") { run_loop }
      end

      # Signals the loop to exit; the fibre observes the closed wake
      # channel on its next select turn. An in-flight cycle runs to
      # completion (`Cron::Scheduler#stop` semantics). Idempotent.
      def stop : Nil
        wake = @mutex.synchronize do
          return if @stopped
          @stopped = true
          @wake
        end
        wake.try(&.close)
      end

      # Runs one poll cycle synchronously. Used by the spec suite; the
      # running fibre calls it on every tick. Each child cycles in its own
      # fault island: a failure in one child is logged and never blocks the
      # others' cycles.
      def sync_now : Nil
        children = scan_children
        forget_removed_children(children)
        each_syncable_child(children) do |child|
          begin
            cycle_child(child.path, child.domain)
          rescue ex : Exception
            Log.error { "[dev-sync] sync cycle for '#{child.domain}' (#{child.path}) failed: #{ex.message}" }
          end
        end
      end

      # ── Poll loop ─────────────────────────────────────────────────────

      private def run_loop : Nil
        # Initial scan + sync: the first poll treats every child as new.
        poll_once
        loop do
          wake = @mutex.synchronize { @wake }
          return if wake.nil?

          select
          when timeout(poll_span)
            poll_once
          when wake.receive?
            # Woken (or stopped via channel close) — the stopped check
            # below decides whether to exit.
          end

          return if @mutex.synchronize { @stopped }
        end
      end

      private def poll_once : Nil
        sync_now
      rescue ex : Exception
        # A scan-level failure (e.g. the root vanished mid-scan) must not
        # kill the loop — the next tick retries.
        Log.error { "[dev-sync] poll failed: #{ex.message}" }
        Metrics.inc("facet_fiber_loop_errors_total", {"fiber" => "Dev Domain Watcher"})
      end

      private def poll_span : Time::Span
        config.poll_ms.milliseconds
      end

      # ── Root scan ─────────────────────────────────────────────────────

      # Every immediate child directory of the watch root that carries a
      # `bundle.yml`, sorted by path. A child without `bundle.yml` is
      # ignored. A vanished root warns and skips the poll — nothing in the
      # watcher deletes a live domain.
      private def scan_children : Array(Child)
        root = config.path
        unless Dir.exists?(root)
          Log.warn { "[dev-sync] watch root '#{root}' is gone — skipping poll; nothing is deleted" }
          return [] of Child
        end

        Dir.children(root).sort!.compact_map do |name|
          path = File.join(root, name)
          next nil unless Dir.exists?(path)
          next nil unless File.exists?(File.join(path, "bundle.yml"))
          domain = read_source_domain(path)
          next nil unless domain
          Child.new(path: path, domain: domain.as(String))
        end
      end

      # Reads `source_domain` from a child's `bundle.yml`. Returns `nil`
      # when the file is unreadable or malformed — the fingerprint cycle
      # reports the full read error when the import runs.
      private def read_source_domain(path : String) : String?
        parsed = YAML.parse(File.read(File.join(path, "bundle.yml")))
        hash = parsed.as_h?
        return nil unless hash
        hash["source_domain"]?.try(&.as_s)
      rescue ex : Exception
        Log.warn { "[dev-sync] unreadable bundle.yml at '#{path}': #{ex.message}" }
        nil
      end

      # Drops tracker state for children that left the root and warns once
      # per removal. The domain's last synced state is kept.
      private def forget_removed_children(children : Array(Child)) : Nil
        current_paths = children.map(&.path).to_set
        @mutex.synchronize do
          (@child_domains.keys - current_paths.to_a).each do |gone|
            Log.warn { "[dev-sync] bundle directory '#{gone}' was removed — keeping domain '#{@child_domains[gone]}' as last synced" }
            @child_domains.delete(gone)
            @observed.delete(gone)
            @attempted.delete(gone)
          end
          children.each { |child| @child_domains[child.path] = child.domain }
        end
      end

      # Applies the duplicate-`source_domain` rule. Yields one child per
      # distinct domain, sorted by path.
      private def each_syncable_child(children : Array(Child), & : Child ->) : Nil
        syncable = [] of Child
        children.group_by(&.domain).each_value do |group|
          first = group.first
          if group.size > 1
            names = group.map(&.path).join("', '")
            Log.warn { "[dev-sync] duplicate source_domain '#{first.domain}' under the watch root: '#{names}' — only '#{first.path}' syncs" }
          end
          syncable << first
        end
        syncable.sort_by!(&.path)
        syncable.each { |child| yield child }
      end

      # ── Change detection ──────────────────────────────────────────────

      # A child cycles when its fingerprint differs from the last attempted
      # one and the same new fingerprint was observed on two consecutive
      # polls. The first observation only records the pending fingerprint.
      private def cycle_child(child_path : String, domain : String) : Nil
        fingerprint = fingerprint_of(child_path)

        sync = false
        @mutex.synchronize do
          next if @attempted[child_path]? == fingerprint
          if @observed[child_path]? == fingerprint
            sync = true
          else
            @observed[child_path] = fingerprint
          end
        end
        return unless sync

        begin
          sync_child(child_path, domain)
        ensure
          # Record the attempt whether the cycle succeeded or failed — a
          # failed cycle waits for the next save (a new fingerprint)
          # instead of re-firing on every poll.
          @mutex.synchronize do
            @attempted[child_path] = fingerprint
            @observed.delete(child_path)
          end
        end
      end

      # SHA-256 over the ordered `(relative_path, size, content)` tuple of
      # every file under `path`, recursed. Content-addressed on purpose: a
      # save that lands inside the same mtime tick as the previous poll
      # (coarse filesystem clocks) still produces a new fingerprint, so the
      # watcher never misses a cycle and no caller needs an mtime guard.
      # The watch root is a dev tree, so the file count is small —
      # performance is not a requirement.
      private def fingerprint_of(path : String) : String
        digest = Digest::SHA256.new
        Dir.glob(File.join(path, "**", "*")).sort!.each do |file|
          next unless File.file?(file)
          digest.update("#{file[(path.size + 1)..]}\0#{File.info(file).size}\0")
          digest.update(File.read(file))
          digest.update("\n")
        end
        digest.hexfinal
      rescue File::NotFoundError | File::AccessDeniedError
        # A file vanished mid-scan (a save in progress). Return a value
        # that can never match the previous fingerprint, forcing a fresh
        # cycle on the next poll — the read reports the true state then.
        "vanished-#{@clock.call.to_unix_ms}"
      end

      # ── Sync cycle ────────────────────────────────────────────────────

      # An unreadable bundle keeps its previous state; see `read_bundle`.
      private def sync_child(child_path : String, domain : String) : Nil
        bundle = read_bundle(child_path, domain)
        return unless bundle

        Database.with_db(:read_write) do |db|
          pre = capture_pre_state(db, domain)

          # Teardown and import share ONE transaction: a failed import (a
          # returned error or a raise) rolls the drop back with it, so the
          # domain keeps its previous state. `Portable::Import` joins the
          # caller's transaction (its `ignore_if_set` wrapper), and the
          # events it enqueued are discarded with the rollback.
          result = Database.with_transaction(db) do |txn|
            drop_managed_domain(txn, domain, pre, bundle)
            @managed_domains.add(domain)
            Domain::Portable::Import.call(txn, bundle)
          end

          case result
          in ServiceError
            # The details block names the failing field — the same printout
            # the portable CLI gives the operator (B-365). The marker makes
            # the failed bundle visible on GET /Api/dev/check-report. The
            # import rolled back, so both are diagnostics: the domain keeps
            # its previous state and no check runs for it.
            Log.error { "[dev-sync] import for '#{domain}' (#{child_path}) failed: #{result.status} #{result.message} — keeping previous state#{Domain::Portable::ServiceErrorFormat.details_block(result)}" }
            Dev::CheckReport.record_import_failure(domain, result, import_failure_doctypes(domain, result))
            discard_pending_events
          in Domain::Portable::Import::Result
            discard_removed_doctype_data(db, domain, pre, bundle)
            changed = warn_structure_changes(db, pre) if config.documents.preserve?
            Event::Publisher.flush
            log_check_summary(db, domain)
            reproject_changed(db, changed) if changed
            Log.info { "[dev-sync] synced '#{domain}' from '#{child_path}': #{result.doctypes_created} doctype(s) created, #{result.doctypes_updated} updated, #{result.doctypes_unchanged} unchanged, #{result.documents_created} document(s) replayed" }
          end
        end
      end

      # Derives the failing bundle doctype(s) for the import-failure marker
      # from the error message. `Import` names the failing surface in its
      # errors: a definition-scoped failure reads
      # `"<domain>.<doctype>: <reason>"` and a bundle-row failure reads
      # `"Bundle document '<domain>.<doctype>#<id>' ..."` (the raise sites
      # in `Domain::Portable::Import`). Both shapes are matched with the
      # target domain as the anchor; a domain-level rejection names no
      # bundle doctype, and the marker then carries none.
      private def import_failure_doctypes(domain : String, error : ServiceError) : Array(String)
        message = error.message

        if message.starts_with?(ROW_ERROR_PREFIX)
          qualified = message[ROW_ERROR_PREFIX.size..].partition('#')[0]
          return doctype_in_domain(domain, qualified)
        end

        doctype_in_domain(domain, message.partition(": ")[0])
      end

      # The qualified id when it names a doctype under `domain`
      # (`"<domain>.<doctype>"`), else no doctype.
      private def doctype_in_domain(domain : String, qualified : String) : Array(String)
        return [] of String unless qualified.starts_with?("#{domain}.")
        return [] of String if qualified.partition('.')[2].empty?
        [qualified]
      end

      # Reads the child's bundle. Every failure the read can produce — the
      # reader's own error, a missing entry file, a malformed YAML document
      # — is the same condition: log for THIS child, keep its previous
      # state. Exceptions from later stages (teardown, import) are not
      # swallowed here — they propagate to the per-child fault island in
      # `sync_now`.
      private def read_bundle(child_path : String, domain : String) : Domain::Portable::Archive::Bundle?
        Domain::Portable::Archive.read(child_path)
      rescue ex : Exception
        Log.error { "[dev-sync] could not read bundle for '#{domain}' at '#{child_path}': #{ex.message} — keeping previous state" }
        nil
      end

      # Disposes the managed domain's surface per the documents mode, inside
      # the sync transaction — a failed import rolls the disposal back with
      # it. The fresh import then re-creates the surface.
      private def drop_managed_domain(
        db : DB::Connection,
        domain : String,
        pre : Hash(String, PreDoctype),
        bundle : Domain::Portable::Archive::Bundle,
      ) : Nil
        return unless Util::Projections.exists?(db, "core", "Domain", domain)

        unless @managed_domains.includes?(domain)
          Log.warn { "[dev-sync] domain '#{domain}' exists and was not created by this watcher — replacing its definitions" }
        end

        Log.warn { "[dev-sync] dropping managed domain '#{domain}' — full rebuild" }

        case config.documents
        when .preserve?
          Domain::Scratch.dispose_definitions!(db, domain)
        when .discard?
          Domain::Scratch.dispose!(db, domain)
        end
      end

      # Runs after the fresh import. A doctype that left the bundle takes
      # its data with it (both documents modes — in `discard` the teardown
      # already wiped the data, and this pass keeps it wiped even when the
      # bundle still carries a stale `documents/` tree for the removed
      # doctype, which the idempotent replay would otherwise re-create).
      private def discard_removed_doctype_data(
        db : DB::Connection,
        domain : String,
        pre : Hash(String, PreDoctype),
        bundle : Domain::Portable::Archive::Bundle,
      ) : Nil
        bundled = bundle.doctypes.map(&.[:doctype]).to_set
        removed = pre.keys - bundled.to_a
        removed.each do |qualified|
          doctype = qualified.partition('.')[2]
          count = pre[qualified].live_documents
          Log.warn { "[dev-sync] doctype '#{qualified}' left the bundle — discarding its #{count} document(s)" }
          db.exec(
            "UPDATE projections SET deleted_at = now() WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL",
            domain, doctype,
          )
        end
      end

      # Reads the domain's live doctype surface before the teardown: the
      # parsed definition (when the stored row parses — a corrupt row is
      # skipped, mirroring `Domain::Copy`) and the live document count per
      # doctype.
      private def capture_pre_state(db : DB::Connection, domain : String) : Hash(String, PreDoctype)
        counts = capture_document_counts(db, domain)
        pre = {} of String => PreDoctype

        db.query_all(
          <<-SQL,
            SELECT id, content FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType'
              AND content->>'domain' = $1
              AND deleted_at IS NULL
            ORDER BY id ASC
          SQL
          domain,
          as: {String, JSON::Any},
        ).each do |(qualified, content)|
          doctype = qualified.partition('.')[2]
          pre[qualified] = PreDoctype.new(parse_definition(content), counts.fetch(doctype, 0i64))
        end

        pre
      end

      private def capture_document_counts(db : DB::Connection, domain : String) : Hash(String, Int64)
        counts = {} of String => Int64
        db.query_all(
          "SELECT doc_type, count(*) FROM projections WHERE domain = $1 AND deleted_at IS NULL GROUP BY doc_type",
          domain,
          as: {String, Int64},
        ).each do |(doc_type, count)|
          counts[doc_type] = count
        end
        counts
      end

      private def parse_definition(content : JSON::Any) : Doctype::DoctypeDefinition?
        Doctype::DoctypeDefinition.from_json(content)
      rescue JSON::ParseException | KeyError
        # A corrupt definition row is skipped — the sync must not abort the
        # whole cycle because of one broken definition.
        nil
      end

      # Preserve-mode pass over the pre-sync snapshots: for every doctype
      # whose fields changed in a data-shape way (additive included) or whose
      # derived surface changed, while carrying live documents, warn (the
      # kept documents are stored as-is; the reproject below repairs the
      # derived columns) and collect the qualified id. Doctypes with no live
      # documents are skipped. Composition-only (`children` / `member_of`)
      # and actions-only changes stay silent — no derived column depends on
      # them. Returns the changed doctypes' qualified ids — empty when
      # nothing worth re-projecting changed.
      private def warn_structure_changes(db : DB::Connection, pre : Hash(String, PreDoctype)) : Array(String)
        changed = [] of String
        pre.each do |qualified, snapshot|
          next if snapshot.live_documents.zero?
          old_definition = snapshot.definition
          next unless old_definition
          new_definition = Doctype::DefinitionStore.fetch_uncached(db, qualified)
          next unless new_definition
          next unless reproject_worthy?(old_definition, new_definition)
          changed << qualified
          Log.warn { "[dev-sync] doctype '#{qualified}' changed structure or derived surface; kept #{snapshot.live_documents} document(s) — stale derived columns possible, re-projecting" }
        end
        changed
      end

      # A doctype is worth re-projecting when its fields changed in any
      # data-shape way (additive included — a new field changes what the
      # derived paths resolve) or when the derived surface (`search` paths,
      # the `display_name` template) differs between the pre-sync snapshot
      # and the stored definition.
      private def reproject_worthy?(old_definition : Doctype::DoctypeDefinition, new_definition : Doctype::DoctypeDefinition) : Bool
        Doctype::Structure.data_shape_changes(old_definition, new_definition).any? { |change| change.kind == :field } ||
          old_definition.search != new_definition.search ||
          old_definition.display_name != new_definition.display_name
      end

      # ── Post-sync diagnostics ──────────────────────────────────────────

      # Runs the domain's aggregate diagnostics and logs a one-line issue
      # summary (the warning count and the first message). A clean domain
      # logs nothing. Read-only — and a failure is logged, never raised:
      # diagnostics must not fail a cycle whose import already succeeded.
      private def log_check_summary(db : DB::Connection, domain : String) : Nil
        result = Domain::Check.call(db, domain)
        case result
        in Domain::Check::Result
          Dev::CheckReport.record(result)
          issues = result.domain_issues + result.doctypes.flat_map(&.issues)
          return if issues.empty?
          Log.warn { "[dev-sync] check for '#{domain}': #{issues.size} issue(s) — first: #{issues.first.message} — full report: GET /Api/dev/check-report?domain=#{domain}" }
        in ServiceError
          # The last report for this domain is stale — drop it rather than
          # serve a report that no longer reflects the domain's state.
          Dev::CheckReport.record_failure(domain)
          Log.error { "[dev-sync] check for '#{domain}' failed: #{result.status} #{result.message}" }
        end
      rescue ex : Exception
        Dev::CheckReport.record_failure(domain)
        Log.error { "[dev-sync] check for '#{domain}' raised: #{ex.message}" }
      end

      # Re-projects the derived columns (`search` / `links` / `display_name`)
      # of every structurally changed doctype with live documents, so the kept
      # rows match the new definitions. Preserve mode only — `discard` reseeds
      # every row from the bundle with fresh derived columns. One failure is
      # logged for THIS doctype and never fails the cycle.
      private def reproject_changed(db : DB::Connection, changed : Array(String)) : Nil
        changed.each do |qualified|
          begin
            result = Doctype::Reproject.call(db, qualified) { |_result| }
            case result
            in Doctype::Reproject::Result
              failed = result.stats.failed.get
              if failed.zero?
                Log.info { "[dev-sync] reprojected '#{qualified}' — #{result.stats.processed.get} document(s)" }
              else
                Log.warn { "[dev-sync] reproject for '#{qualified}' finished with #{failed} failed row(s) — those rows keep their previous derived state" }
              end
            in ServiceError
              Log.error { "[dev-sync] reproject for '#{qualified}' failed: #{result.status} #{result.message}" }
            end
          rescue ex : Exception
            Log.error { "[dev-sync] reproject for '#{qualified}' raised: #{ex.message}" }
          end
        end
      end

      # A failed import leaves the fibre-local event queue holding events
      # for a rolled-back transaction. Mirror the HTTP-layer contract ("if
      # the transaction fails, the queue is discarded") instead of flushing
      # events whose mutations do not exist.
      private def discard_pending_events : Nil
        Fiber.current.event_publish_queue = nil
      end
    end
  end
end

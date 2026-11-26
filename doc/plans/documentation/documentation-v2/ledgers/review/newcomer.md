# Newcomer documentation test — report

Tester persona: 45-person company, never heard of Facet, asked by boss to find out what it is and try it. Can read the docs site (http://localhost:4321) and use the instance (https://facet.localhost:3443). Cannot read source code or ask anyone.

Test date: 2026-11-26. Instance state at start: fresh, one admin (`admin@example.tld`), Brightwater Rentals example loaded.

Report written incrementally, one row per task.

---

## Task 1 — What is Facet, and what problem does it solve?

**Pages visited:** `/` (home), `/discover/`, `/discover/why-facet/`

**What I read (quoted):**
- Home: "One governed home for your business data, plus the apps that run on it." — "The records are your documents in **domains** … The rules are **roles** that decide who reads and writes what, down to single fields and rows. The memory is a full record of every change, with undo."
- Why Facet: "Facet is one governed home for your business data, plus the apps that run on it. … An app never touches the database and never runs inside Facet. It signs in, like a person does, and gets no more rights than it was given. Delete the app and nothing of yours is lost: the records, the rules, and the history stay. **Apps are disposable; your data is not.**"

**My answer (in my own words):** Facet is a self-hosted platform where your company keeps its business records (clients, equipment, bookings — anything you model) in one place, with two things built in that a spreadsheet or a pile of apps never gives you: (1) rules about who may see or change each row and field, enforced by the data layer itself, and (2) a permanent log of every change with undo. Apps — your team's tools, an AI agent, the built-in workspace — are just faces on top; they go through one governed door (the API) with no more rights than they were given. The problem it solves: scattered data in spreadsheets/CRMs/calendars, no way to say who sees what, broken tool-to-tool bridges, and SaaS tools that rent your own data back to you forever.

**Confusion points:**
- (minor) "The big picture" link on `/discover/` goes to a URL I guessed wrong first (`/discover/big-picture/` → 404). The actual path is `/discover/how-it-works/`; the text link was "The big picture" so I had no way to know the slug without hovering/clicking. In a plain-text workflow this cost one 404.
- (minor) Search is unavailable in this environment ("Search is only available in production builds"), so I could not search for anything — a newcomer without a working search button cannot look up terms. This is an environment/build issue, not the docs text itself, but on the frozen site the search button is a dead end.

**Result:** Task 1 answered fully from Discover. **Severity:** minor (both points above).

---

## Task 2 — Domain vs doctype vs document

**Pages visited:** `/discover/how-it-works/domains/`, `/discover/how-it-works/documents/` (I reached both from the links on `/discover/how-it-works/` — the "five short pages" list)

**What I read (quoted):**
- Domains page: "each of those lives in its own **domain** — one business area, kept separate from the others." — "A kind of record is a **doctype**; the things a record holds are its **fields**. Brightwater's *equipment* domain holds the *Item* doctype: name, category, status, serial number, purchase price."
- Documents page: "One client, one tent, one booking — in Facet, each is a **document**: one record, the real thing your team works on. And each one remembers its past."

**My answer:** A **domain** is a business area kept separate from the others (clients, equipment, rentals) — it holds the model: which record kinds exist and what fields each kind has, plus its own rules and grants for crossing to other domains. A **doctype** is one kind of record inside a domain (Item, Company, Booking) — the definition/shape. A **document** is one actual record of that kind — the tent "Stage roof Pro 5×5" — with its field values, links, comments and its change history.

**Confusion points:**
- (minor) The word **doctype** itself. It is defined in one sentence on the Domains page, but as a newcomer I kept wanting to call it "table" or "record type". The glossary does not appear until I hunt for it; a first-reading definition is there, though, so this is mild.
- Nothing else confused me — the domain page's Brightwater examples (equipment → Item, clients → Company) made the three-level hierarchy concrete.

**Result:** Task 2 answered correctly from Discover. **Severity:** minor.

---

## Task 3 — Why the same person sees different things depending on role

**Pages visited:** `/discover/how-it-works/roles/`

**What I read (quoted):**
- "Someone can hold several roles — say, *Sales* and *Manager*. When they sign in, Facet puts them under one of them; if they hold more than one, the account menu carries **Switch Role**. Everything they see and do follows that one role until they switch."
- "Tom's *Sales* role carries that rule, so his client list shows his five companies — not the other seven. … A rule like 'clients whose account manager is me' is a **row scope**: a saved filter a role can carry."
- "The purchase price field carries a **field tag** — a sensitivity label — and her role does not hold it. She opens an item and the field is not there: not greyed out, not 'no access' — absent, on screens and in the API alike."
- "Facet checks them on every read and write, whatever sent the request — the workspace, an app, a key, or an AI agent."

**My answer:** Rights attach to roles, not to screens. A person holds one or more roles; per session Facet acts under exactly one of them (Switch Role in the account menu). A role carries **row scopes** (which rows you may reach — e.g. "clients whose account manager is me") and field-tag rules (which sensitive fields are absent entirely). The checks run on every read and write, in the workspace, in apps, via API keys, and in the assistant — so the same person sees a different list or a shorter form depending on the role they act under, and no surface bypasses it.

**Confusion points:**
- (minor) "One role at a time" was slightly surprising — I first read it as "you can only ever hold one role"; the next sentence corrects that (several roles, one active per session). A re-read fixed it; the page could put the correction in the same first sentence.

**Result:** Task 3 answered correctly from Discover. **Severity:** minor.

---

## Task 4 — Good fit for a 10-person design agency that only needs a shared task list?

**Pages visited:** `/discover/is-it-right-for-you/`, `/discover/compare/vs-airtable-notion/`

**What I read (quoted):**
- Is it right for you?: "**Facet is not the right tool when** These workloads need a lower level of control. Use a plain database and hand-built services for them: Heavy data load … Statistics and analytics … B2C products … Multi-tenancy … Time-series … A house IT architecture … Wanting a hosted service."
- Is it right for you?: "No built-in reports or charts … No workflow engine … No prebuilt business modules: no CRM, accounting, inventory or HR to install."
- Compare page: "**When Airtable or Notion is the better choice:** The team is small (five to ten people), nobody has ever asked for an audit trail, and speed matters more than structure."

**My answer:** Probably **no** — and the docs essentially say so. For a 10-person design agency that needs only a shared task list, the requirement is speed and collaboration, not governance. Facet needs you to run servers (PostgreSQL, Redis, Docker, TLS), model your own domain from scratch (no template library, no prebuilt modules), and its whole value — enforced roles, field-level rules, an append-only audit log — solves a problem a small task list does not have. The compare page names this exact case in the "Airtable or Notion is the better choice" column. Facet would *work* (a Task doctype in a draft, published in the Builder), but it is the wrong economic and operational weight for the job. If later they need governed client/contract records with per-person visibility, Facet becomes interesting.

**Confusion points:**
- (minor) I had to combine two pages to answer: the fits/poor-fits list on `Is Facet right for you?` never mentions a plain "small team, simple collaboration" case — only exotic workloads. The honest answer lives on the *Compare* page. A newcomer who stops after the fits page might conclude "nothing on the no-list applies, so it fits".

**Result:** Task 4 answered correctly from Discover (two pages). **Severity:** minor.

---

## Task 5 — "Your first hour", tutorials 1–5

Route page: `/build/first-hour/` (six tutorials listed; I ran 1–5 as instructed). Tutorial pages read: `/build/first-hour/run-facet/`, `first-domain/`, `first-domain-in-files/`, `first-app/`, `team-access/`. Instance: `https://facet.localhost:3443`.

**Environment caveat, stated up front:** the instance was already running with the Brightwater example loaded, so tutorial 1's container/start steps (1–3) could not be exercised: no `docker/.env` to fill, no `docker compose up`, no `seed:admin` run by me. The docs describe those steps clearly (compose file, five services, one-time password printed once); I could only verify the parts that live in the product: first sign-in, forced password change, welcome tour. Also, the docs advertise `/<path>.md` page twins and a "Copy as markdown" button, but both 404 on this preview build — search is likewise disabled. I fell back to reading the rendered pages.

### Tutorial 1 — Run Facet (time: ~25 min of my hands-on, minus the container steps the environment skipped)

What I did:
1. Opened `https://facet.localhost:3443` → redirected to `/Login` with a clean two-field form. Signed in with `admin@example.tld` + the one-time password `6QXR-AE39-B3X7-ZDHE`.
2. The **Set a new password** screen appeared as documented: "Your Facet account uses a temporary password." Three fields — Current / New / Confirm. Set a real password, clicked **Save password and continue**.
3. **Confusion point (untested by docs):** after the password change Facet presented a screen the tutorial never mentions — "**Set up two-factor authentication** — Scan the QR with an authenticator app (1Password, Authy, Aegis) to back up Facet with TOTP.", with a manual entry key and a "Skip for now" escape. Tutorial 1 says only: "You land on the dashboard, signed in as the admin." I had to write my own TOTP generator to finish enrollment (a human would need their phone app — fine — but the tutorial should name this step, especially since it appears *before* the promised dashboard).
4. Landed on the Dashboard. The welcome tour opened as documented: first card "**A governance layer** — Welcome to Facet. Facet is a governance layer for your organization's data…".
5. Clicked Next through the tour. **Confusion point (minor):** the tutorial says "seven steps that present Facet — the governance layer, domains, the Builder, roles, the audit trail, integrations — and end with two buttons, Create a domain and Import a bundle." The tour's progress dots show **6** steps; the final card is "**Your first domain** — Set up your first domain now — it takes minutes. Set your timezone and language in Settings; you can restart this tour there." with exactly the two promised buttons (screenshot verified). Count mismatch is cosmetic; the ending is exactly as described.

Verdict for tutorial 1: completed everything that applies to a pre-running instance; one undocumented step (TOTP enrollment); one count mismatch (6 vs 7 steps).

### Tutorial 2 — Model your first domain (claimed 20 min; my hands-on time ≈ 60–70 min, inflated by blind browser work — a human reading and clicking would land closer to 30–40 min)

What I did: followed the page step by step — opened Builder, clicked **New domain** (dialog: Label `Equipment`, Domain id `equipment` → draft `_06h1hdqhxrmg` with DRAFT badge, tabs Overview/Doctypes/Editors/Grants/Check — exactly as written), added **Category** (`name`, string, required; Label template `{{ name }}`), **Item** (`name` required, `category` Reference→Category, `status` Enum available/out/in_repair, `purchase_price` Money, `serial_number` String unique; Label `{{ name }}`), **MaintenanceTicket** (`item` Reference→Item required, `problem` Long Text required, `status` Enum reported/diagnosing/waiting_parts/fixed with default Reported; Label `{{ item }}` — including the documented trap that `state` is a reserved key). Then Preview → MaintenanceTicket starter screen → Kanban view named **Board**, Scope General, grouped by State → four lanes appeared. Created the scratch documents (Tents; Main tent 10x15; Folding chair white; three tickets, one per state) and saw one card per lane. Ran **Check**, then **Published**.

Confusion points:
1. **The tutorial assumes an empty server; this instance has Brightwater loaded.** The target `equipment` domain already exists. The tutorial never mentions this; the only warning is small print inside the publish dialog: "If the target domain already exists, the draft's doctype definitions replace the live ones when their structure changed only if each changed doctype bumps its schema version and carries a migration entry." A newcomer following the page could overwrite the demo data with one click. I deviated deliberately and published to `equipment-trial` instead. Result: the workspace then lists **two domains both labelled "Equipment"** with nothing to tell them apart (page: Builder Overview → workspace DOMAINS list). Confusing — **the highest-risk finding so far**.
2. **The reference picker searches by document id, not by label.** On the Item form, typing `Tents` answers: "No category id matches “Tents”." The picker shows raw ULIDs (`06H1HGE8PWVQSYAQ2CJ3JF4YD5`), not the display label the Label template produces. The tutorial's step 5 ("create them in that order through each list's New button") gives no hint how to fill a reference field. Confusing.
3. **The Check tab contradicted the tutorial's happy path.** I set Label templates on all three doctypes (verified saved in the editor), yet Check kept reporting "No display_name and no search template: the cross-doctype search endpoint skips the doctype…" for all three, before **and** after clicking Refresh, and the publish dialog showed "3 warnings detected". The tutorial promises: "When nothing is left, the publish dialog confirms: 'No problems detected. Ready to publish.'" — that confirmation never appeared for me. Confusing.
4. **Preview cards show raw ids, not label templates.** The tutorial says "Each ticket card shows its item name — the label template at work"; my draft-preview board cards showed the ticket ULIDs. Confusing (possibly related to 3).
5. (minor) The enum Default is a plain "Select…" dropdown under the value chips; the tutorial's phrasing "The Default ★ marks the default select under the value chips picks the value a new document starts with" reads garbled but the control is findable.
6. (minor, doc-correct) Unsaved field edits are silently dropped on navigation — the docs do warn "Edits stay local until that save — a reload drops them", and I lost one field edit exactly this way before learning to save within the session.
7. (minor, my own error, not the docs') a stray `new_field` briefly landed in Item from a double add; I deleted it — the delete affordance (trash icon per field pane) worked and the docs' troubleshooting section does not need to cover it.

What worked as written: the draft lifecycle, DRAFT badge and temporary `_`-prefixed id, the reserved-name refusal risk (I avoided `state`), the type list in the field editor, the Preview banner "Previewing draft … — schema edits are not available here", the starter screen with layout cards, the Check report grouping By doctype, and publish dropping the draft (Builder landing shows "No draft domains yet").

### Tutorial 3 — The same domain in files (claimed 15 min; I completed the verifiable half in ~10 min)

The tutorial needs the dev stack (`./scripts/dev`) with the domain watcher watching `site-docs/examples/brightwater/`. This instance runs the production-style release stack, so the watcher steps (add a `ScratchNote` doctype file, watch the sync log, break a field type to see the 422, delete the file to watch the revert) **could not be exercised** — I chose not to boot a second, source-built stack on the shared machine. What I could verify:
- The folder layout the page shows exists and matches the tutorial's tree exactly (`equipment.facet-domain/` with `bundle.yml`, `domain.yml`, `doctypes/`, `hooks/`, `views/`) — the page's file tree is accurate.
- The export step works against the live instance: `scripts/facet domain:export equipment --output …` returned "doctypes: 3, document views: 4, collection views: 2 (general only; personal excluded)" and the tarball listing matches the page's `tar -tzf` shape.

Confusion points:
- (minor) The page is honest that it needs the dev environment, and says "Developers only" on the route table. No complaint about the content — only that on this frozen test instance half of it is unreachable, which the route table could flag more loudly for evaluators.

### Tutorial 4 — Ship your first app (claimed 30 min; my hands-on ≈ 45 min, steps 1–3 and 6 of 7)

The environment blocked the tutorial as written at every demo-data dependency:
- "this tutorial uses Ravi Menon, the example's admin" — the documented password `brightwater-ravi` answers **401 Invalid credentials**. In fact the instance has **exactly one account** (my admin) and zero example users.
- The `warehouse` role does not exist (`PATCH /Api/iam/Roles/iam.Roles.warehouse` → 404). The instance carries only core roles (admin, anonymous, attachment_owner, comment_author, editor, viewer).
- The "confirmed bookings, six of them on the example data" do not exist: rentals had **0** documents, equipment **0**, clients **0**. The so-called loaded Brightwater example is schema-only: the domain/doctype definitions (with the finance tag on `purchase_price` and the Brightwater field shapes) are seeded, but no data, people, or roles came with it.

What I did as a resourceful newcomer would: created the `warehouse` role (documented REST route), created a Lucía account (`POST /Api/iam/Account`, `POST /Api/iam/accounts/:id/temporary-password` — both documented on the Manage accounts page), ran her first sign-in in the browser (temp password → forced change → forced TOTP enrollment with a Skip), seeded one company, two items, and one confirmed booking through the API, then ran the tutorial's own curl transcript:
- Registered the app `bfr-checkout` → 201, hook wrote the read-only `client_id`; activated it (draft → active).
- The consent screen listed **exactly one** electable role with its `effective_scope` — matching the tutorial's "grants ∩ roles" story (it correctly listed nothing before I added the concrete `equipment.Item` line — I verified the intersection logic in the direction the page teaches).
- PKCE code → token (Bearer, 900 s, refresh token) worked verbatim.
- With the app token: `rentals/Booking?filters[status__eq]=confirmed` returned my booking; `clients/Company` returned `{"error":"Forbidden"}` — the grant ceiling holds exactly as the page promises.

Confusion points:
- **(blocker-grade, environment)** The tutorial's premise "the Brightwater example is loaded" is false on this instance in every way that matters beyond schema. Ravi's password, the warehouse role, and all example documents are missing, and the page gives no fallback for a fresh instance without demo data.
- (minor) Steps 4–7 (scaffold with pnpm, have a coding agent write the app, deploy with `@facetapp/cli`) were out of reach in this offline environment; I could not verify the SDK/CLI claims.
- (minor) On my created booking, `client_name` did not copy from the client (`"is replicated and should not be set"` on write, and the stored value read back as null) — the tutorial's data table calls client_name "copied from the client". Did not investigate further (would need source).
- (minor) The sign-in transcript's "Lucía's session, as her browser holds it" assumes a curl-usable session cookie; my browser-state cookie jar did not authenticate the consent call — I used the API login instead. The page's own transcript works because it logs in via the API in the first place.

### Tutorial 5 — Give your team access (claimed 15 min; my hands-on ≈ 40 min)

Followed in the UI as written:
- **Configure → Access → Accounts → New account**: created Pat Mardell (`pat@brightwater.example`). First save was **refused** with "Role authority refused this write — default_role 'iam.Roles.warehouse' is not a member of the final roles array" even though the role chip was visibly in the Roles field; removing and re-adding the role made the save pass. (Note: the tutorial's dialog carries only Email and Display Name; I had added the role in the create dialog — the tutorial assigns it later on the Assignments page. That assign-elsewhere split is exactly why the refused-save error is disorienting.)
- **Credentials → Generate password**: produced the one-time 16-character password (`WTCS-4DER-YGDB-JYBN`), matching the documented format and the shown-once warning.
- **Assignments → By account → Pat → Add a role → Warehouse → Assign role**: worked; the row shows the **default** badge as the tutorial says.
- Pat's first sign-in: same forced password change + forced TOTP enrollment (Skip for now available).
- **Field tag verified from both sides** (the tutorial's step 3): as Pat, `GET /Api/equipment/Item/EQ-2026-0001` returns keys `category, name, serial_number, status` — **no purchase_price**; as admin the same read returns it with `{"value":"4800.00","currency":"EUR"}`. "One field, two answers" — confirmed verbatim.
- **Audit (step 5)**: Configure → Audit log shows "Created | Pat Mardell | Administrator | facet", the temp-password generation, his password change and sign-ins — exactly the trail the tutorial says to expect.

Confusion points:
- **(blocker-grade, environment)** Step 4 (row scope) cannot run: Tom, the `sales` role, and the `my_clients` named scope are absent from this instance (the seeded `clients.Company` has an `account_manager` field but `named_scopes` is null, and no sales role exists). The tutorial assumes the example loaded them and offers no fallback for building the scope from scratch on a fresh install.
- (confusing) The refused first save of the New account dialog (error quoted above) — a flaky-feeling UI state with a cryptic backend message, not covered by any troubleshooting section.
- (minor) My own first attempt bypassed the Assignments page and put the role in the create dialog; the tutorial's two-step split (create bare, then assign) is the working path, but nothing on the create dialog says roles there will behave differently.

### Task 5 verdict

Tutorials 1, 2, 5: completed in the product. Tutorial 4: completed steps 1–3 and 6 (the platform halves); the app-code halves (4, 5, 7) were out of reach offline. Tutorial 3: the live-instance half (export) verified; the watcher half needs the dev stack. Time total: ≈ 3.5 h hands-on vs the route's promised "about an hour" — most of the overrun came from missing demo data/roles I had to build myself, plus blind-browser friction a human would not have.

---

## Task 6 — Find a booking, change its date, undo the change

**Pages visited:** `/use/documents/history-undo/`

**What I did:** opened the booking `BK-2026-0001` in the workspace (Rentals → Booking). Clicked **Edit** and moved the start date 2026-12-11 → 2026-12-12. The save was **refused by a guard**: "Script validation failed — A confirmed booking's dates are locked. Return the booking first." (the seeded domain carries a Lua guard; the Script-and-guards concept from the Build docs behaves exactly as advertised). I set the booking's state to Draft, saved, then changed the date — saved. Opened **History** (page header), which showed my two rapid edits folded into a single "Updated | 2 set" row plus the original "Created | 4 fields initialized". Selected the **Created** row (the content I wanted back), clicked **Revert to this version**; the dialog named the document and the mutation id and warned "A new snapshot mutation will be written to the audit log"; clicked **Roll back**. The timeline gained a top entry "**Rolled Back | Restored from rollback | via Rollback**" and the document reads again DATES 2026-12-11 → 2026-12-13, STATE Confirmed.

**Confusion points:**
- (minor) The undo page never mentions that recent same-session edits may appear as **one** combined timeline row ("Updated | 2 set") rather than one row per save — I had made two edits and saw a single update entry. The retention doc (admin side) calls this coalescing; the user-facing undo page would benefit from one sentence.
- (minor) The guard refusal surprised me at first, but the message itself told me the way out ("Return the booking first"). Good failure mode.

**Result:** Completed — date changed and undone, final state verified on screen. **Severity:** minor.

---

## Task 7 — You cannot see a client your colleague sees: find out why

**Pages visited:** `/discover/how-it-works/roles/` (from Task 3), `/admin/people/row-scopes/`

**What the docs say (quoted):**
- Roles page: "Tom's *Sales* role carries that rule, so his client list shows his five companies — not the other seven. … A rule like 'clients whose account manager is me' is a **row scope**: a saved filter a role can carry."
- Row-scopes page: scopes are named filters defined on the doctype (the author's half, "Write row rules for roles") and carried by roles; a direct open of a row outside the scope answers **not found** — "Facet does not confirm that the row exists."

**What I did on the instance:** I tried to reproduce the situation. The seeded `clients.Company` doctype has an `account_manager` field but **no named scopes**, and no scoped role exists on this instance (see Task 5 — the Brightwater example data/roles are absent). I demonstrated the mechanism from its negative instead: created a second company, then read the client list as Pat (warehouse role, plain `read` on `clients.Company`, no scope) — he sees **every** company; and as admin — same. So on this instance nothing hides a client, and the docs explain exactly the mechanism that would: a row scope carried by the colleague's or my role. I also verified the "direct open answers not found" behaviour is the documented failure shape.

**My answer:** the difference comes from **row scopes** — filters attached to role permissions, evaluated on every read in every surface (lists, search, direct links, API, assistant). If my colleague sees a client I cannot, their role carries a scope that matches that client (e.g. "account manager is me") and mine does not; opening the row directly answers not-found rather than forbidden, so I cannot even confirm it exists.

**Confusion points:**
- (confusing, environment) The scenario in the task — and Tom's demo on the tutorials and Discover pages — cannot exist on the shipped example instance: no scoped role, no `my_clients` scope. A newcomer who wanted to *see* the behaviour on the frozen instance cannot; the docs are the only demonstration.
- (minor) From the user's side there is no surface that tells you "your role filters rows" — the list just looks complete. The Use docs don't have a "why is my list shorter than my colleague's" page; I assembled the answer from the Discover roles page plus the admin row-scopes page. A short Use-side explanation ("if you can't find a record your colleague has, ask about your role's row scopes") would close the loop.

**Result:** Answered correctly from docs; could not reproduce the hidden-row behaviour live (missing example data). **Severity:** confusing (environment) + minor (docs).

---

## Task 8 — As an author: add "Insurance value" to Item, visible only to managers

**Pages visited:** `/admin/people/hidden-fields/`, `/build/model/change-a-live-domain/`, `/build/model/in-app/drafts-and-publishing/` (plus the Builder itself)

**What the docs say (quoted):**
- Hidden fields page: "A field tag is a sensitivity label on a field. A role declares which tags it may see with its `visible_tags` list. Facet hides every other field on reads, refuses writes into hidden fields, and removes their values from the audit log. The rule fails closed." Steps: "1. Tag the field … 2. Grant the tag on a role … `{ "name": "manager", "visible_tags": ["default", "finance"] }` … 3. Check what each role sees."
- Change-a-live-domain table: "**Safe at the same version: Add a field**" vs "Needs a version bump + migration: Remove a field…".
- Drafts and publishing: "Edit rights on the live domain to fork it into a draft. Use Edit existing in the Builder." and "An administrator opens the domain's Editors tab and lists the accounts that edit the draft with you."

**What I did:**
1. Builder → **Edit existing** → drafted the live `equipment` domain.
2. Added field `insurance_value` (Money, Title "Insurance value") with **Sensitivity tags: `finance`** in the field editor.
3. Bumped Item's schema version to 2 and added a no-op `migrate_from_1` Lua function (see below why).
4. Published over the live `equipment` domain.
5. Created the missing `manager` role (`visible_tags: ["default","finance"]`) and a Nadia account (the example's manager role/user do not exist on this instance).
6. Verified: set `insurance_value = 250.00 EUR` on EQ-2026-0001 as admin; read the item as **Nadia (manager)** → field present; as **Pat (warehouse)** → field absent entirely (and so is `purchase_price`); as admin → present. "Not greyed out — absent" behaves exactly as the docs promise, in the API.

**Confusion points:**
1. **(blocker) The Builder refused to fork the live domain: "You must be an editor of domain 'equipment' to create a draft from it"** — while acting as the Administrator with `*.*`/`*` permissions. The live domain's **Editors list was empty** (Configure → Domains → Equipment → Editors: "No editors on this domain yet"). I had to add my own admin account as a domain editor before anything could be edited. No authoring page explains this gate; tutorial 2 even says "To change the model later, open the Builder and use **Edit existing** — Facet drafts the live domain for you", which is false without the editor entry. The drafts page's "Edit rights on the live domain" is circular — it never says the rights live in that Editors tab, nor that even the administrator starts with zero editors on seeded domains.
2. **(confusing) Docs contradict the runtime on versioning.** The change-a-live-domain table says "Add a field → safe at the same version". The publish gate refused: "Doctype changed structure: schema_version must be 2 (draft has 1) to publish over 'equipment'", then demanded "Migration from v1 to v2 is missing". I had to write a no-op Lua migration function and get it exported from the doctype script — three extra steps for the most common authoring change, walked through nowhere.
3. **(blocker, UI) Publishing over an existing domain silently fails.** With all gates satisfied, clicking **Publish** sent the request, got `409 "Target name 'equipment' is already in use — resend with overwrite:true to replace it"`, and the UI **showed nothing** — no toast, no error, the draft just stays. The dialog offers **no overwrite control** (only "Import existing documents"). I finished the publish via the API (`POST /Api/core/Domain/<draft>/publish` with `overwrite:true` and `target_name`) — a step a pure-UI newcomer cannot do.
4. (minor) The Check tab again reported "No display_name and no search template" for the drafted Item even though the templates were saved and visible — the same checker inconsistency as in tutorial 2.
5. (minor) A value nuance the docs could spell out: a field added to a live doctype does not appear on **existing** documents until someone writes a value (reads return only stored fields). I first verified with an old item and saw the field "missing" for everyone, including admin; after setting a value it appeared for the roles holding the tag. The hidden-fields page's verification examples only show roles, never the empty-value case.

**Result:** Completed (field added, tagged, published; visibility verified from three roles). But it took a route no UI-only author could follow (API publish) and a schema bump the docs say is unnecessary. **Severity:** blocker (UI publish over existing domain) + confusing (editor gate, versioning contradiction).

---

## Task 9 — As an author: build in the app or in files?

**Pages visited:** `/build/model/` (Choose how you build), plus everything Tasks 5, 3 and 8 taught me hands-on

**What the docs say (quoted):** "Pick by where you work and by who you are. If you model data in the app today — Airtable bases, for example — build in the app. If you live in a code editor, or you work with an AI coding agent, build in files." The comparison table: in-app = "Authors, often non-developers", works on "Any instance, including staging and production", safety net is the isolated draft plus Check plus one-transaction publish; in-files = "Developers and AI coding agents", needs "A dev server you own; the watcher refuses to start in production", safety net is version control.

**My decision: build in the app.** As the company's non-developer author:
- I have no dev server, and the files mode refuses to run against production — the instance I was given is all I have.
- The draft → Check → publish loop matches how I want to work: experiments are private, publishing is one transaction, scratch documents stay behind.
- The Builder covers the whole surface (doctypes, fields, views, scripts) and the assistant can propose the first model.

What my hands-on experience adds to the docs' neat table (Tasks 5 and 8):
- In-app building hit three real snags the table cannot show: the domain **Editors gate** (a live domain must list me before I can fork it), the **silent publish failure** when the target domain exists (no UI control, no error — I needed the API), and the Check tab's stale "no display_name" warnings. None of these change the decision — they are frictions, not dead ends — but they cost me real time and the docs do not warn about any of them.
- The files mode's promise ("everything is text with a reviewable diff") is exactly what would have avoided the Builder's save-locality trap (edits silently dropped on navigation) that bit me twice.

The docs' mixing rule is clear and I would adopt it: "treat the files as the source of truth, and re-export after any change made in a draft."

**Result:** Decision made and justified from the docs plus lived experience. **Severity:** minor.

---

## Task 10 — Take a domain built in files on dev to another instance

**Pages visited:** `/build/model/bundles/` (Move domains with bundles), `/build/model/dev-to-production/` (skimmed via the route table), plus tutorial 3's export half

**What the docs say (quoted):**
- Bundles page: "A bundle is a file that carries a domain's definition … You export it from one instance and import it on another." — "Without flags, the import creates the domain fresh and refuses an existing target. Pass `--merge` to update an existing domain, or `--into newname` to land it under another name." — "Read `bundle.yml` inside the bundle. It names the source instance's Facet release (`facet_version`), the source domain, and the export time."
- "The whole import runs in one transaction: a rejection leaves the target exactly as it was."

**What I did:** exported the live `equipment` domain earlier (tutorial 3: `scripts/facet domain:export equipment --output tmp/equipment.tar.gz` → "doctypes: 3, document views: 4, collection views: 2"), then imported it on this (other) instance under a new name: `scripts/facet domain:import <tarball> --into equipment-copy`. The CLI answered: "Created domain 'equipment-copy' — doctypes: 3 created … grant ticket: rentals filed (inactive — awaiting the producer's acceptance)", which matches the docs' claim that an import always files grant tickets inactive. I read `bundle.yml` from the tarball as the page advises (source_domain: equipment, facet_version: 0.2.2, exported_at) and confirmed the copy's Item definition landed with schema_version 1 and its six fields.

**Confusion points:**
- (minor) The CLI resolves the bundle path relative to the repository root, not my working directory — "Bundle path does not exist" until I passed an absolute path. The tutorials do say "the tutorials run commands from [the repo]", so this is consistent, just easy to trip on.
- (minor) The bundle moves definitions only; the page says documents move with `--with-documents`, but what does NOT move at all (roles, accounts, API keys — the people half) is on a different page (From dev to production). A one-line pointer on the bundles page would save the detour.

**Result:** Completed — real export + import across names, verified. **Severity:** minor.

---

## Task 11 — As a developer: a script that lists today's bookings with an API key

**Pages visited:** `/admin/apps-access/api-keys/` (read earlier via the Administer route table), `/reference/filter-operators/` (timestamp system columns), `/build/apps/data/rest-api/` (call grammar, from the tutorial 4 transcript)

**What the docs say (quoted):**
- API keys page: "Ravi gives it an **API key**: a static bearer token pinned to one account and one role, fixed at creation." — "Facet intends service accounts to hold keys. A service account cannot sign in with a password, so a key is its only door." — "`key` is the raw token: `fct_` followed by 26 characters … Copy it now. Storage keeps only its SHA-256 hash."
- Filter operators: "Timestamp system columns — Serves: created_at, updated_at, deleted_at" with `gte` = "Column is later than or at the given timestamp."

**What I did:**
1. Created a **service account** (`POST /Api/iam/Account` with `service_account: true`).
2. Created the **API key** pinned to a role with the `api` connectivity channel (`POST /Api/iam/keys`, body `{name, role}`) — the raw token came back exactly once, as documented.
3. Wrote the script (`tmp/newcomer/todays-bookings.sh`): a curl listing `GET /Api/rentals/Booking?filters[created_at__gte]=<today>T00:00:00Z&sort=-created_at` with the `Authorization: Bearer fct_…` header, printing id / client / dates / status.
4. Ran it: "bookings created today: 1 — BK-2026-0001 … confirmed".

**Confusion points:**
1. (confusing) The timestamp filter syntax cost three attempts. The flat form `filters[created_at__gte]` works; the nested form `filters[created_at][gte]` answers `Unknown filter field 'created_at][gte'` (the helpful error at least lists the filterable fields). Also a **bare date** (`2026-11-26`) silently returns zero rows instead of an error — only a full RFC-3339 timestamp matches. The REST API page's examples use `filters[status__eq]` (field syntax), and the operators page documents operators per type but never spells out the URL form for system columns in one line; I assembled it from two pages plus the error messages.
2. (minor) The key's role must be "assigned to you" at creation; as the only human account I pinned the admin role — fine for a test script, and the page's caution about pinning least-privilege roles is present and I would follow it in production (pin a read-only `reports` role).

**Result:** Completed — script written and verified against the live instance. **Severity:** confusing (filter syntax) + minor.

---

## Task 12 — As a developer: what can my app do for a `warehouse` user, and how do I know?

**Pages visited:** `/build/apps/connect/what-an-app-can-do/` ("Apps: grants ∩ roles"), `/build/apps/connect/permission-manifest/` ("Show only what the user can do")

**What the docs say (quoted):**
- "An app that signs a user in never acts with that user's full rights. The app acts with the **intersection of the grant and the elected role**." — "The grant is the maximum the app may ever do, for every user." — "`target`: one concrete doctype path …; wildcard targets are refused."
- Manifest page: "Every credential that can call the API can also read what it may attempt. The permission manifest on `GET /Api/iam/me` … The manifest is advisory: the server re-checks every request."

**My answer (verified three ways on the live instance):** For a user electing `warehouse`, my app (grants: read Booking, read BookingLine, read/write Item) can exactly:
- **read** `rentals.Booking` and `rentals.BookingLine`,
- **read / create / update** `equipment.Item` — the app's `write` grant resolves to create+update, not delete,
- and nothing else: `clients.Company` answers `Forbidden` (the app's own grant ceiling, even though the warehouse role itself reads clients — verified in Task 4); `delete` on items is out (grant says read/write only); purchase prices and insurance values are **absent** from every response because the warehouse role holds only the `default` field tag (Task 8 verified).

**How do I know — the three checks the docs give, all run live:**
1. The **consent screen** (`GET /OAuth/authorize` as the user) lists each electable role with its `effective_scope` — mine showed exactly the three targets with the actions above, computed as grants ∩ role, line by line.
2. The **permission manifest** (`GET /Api/iam/me` with the app's token) returns `permissions: {rentals.Booking: [read], rentals.BookingLine: [read], equipment.Item: [read, create, update]}` plus `visible_tags: ["default"]` — the same answer, machine-readable, for sizing UI affordances.
3. **The server re-checks every request** — the Forbidden probe on an out-of-grant doctype is the ground truth behind both lists.

**Confusion points:**
- (minor) The grant schema page could state in one line that action `write` expands to create+update but never delete — I learned it from the manifest's computed output, not from the docs' table (the table names the action vocabulary; the expansion rule is only implied).
- (minor) The manifest flags `assistant.access: false` for the warehouse role even though the role carries the `assistant` connectivity channel — the docs (Govern the assistant) presumably explain the difference between channel and per-account access, but a developer reading the manifest for the first time has no pointer.

**Result:** Completed and verified against the live instance. **Severity:** minor.

---

## Task 13 — As an admin: require MFA for everyone

**Pages visited:** `/admin/people/mfa/` (Require MFA), `/admin/configure/system-settings/` (referenced from it), the Settings UI (Configure → Platform → Settings → Security)

**What the docs say (quoted):**
- "Two enforcement levels: `preferred` — Facet asks each un-enrolled account to set up MFA after sign-in. The account can decline. … `always` — Facet holds every un-enrolled sign-in at the enrollment step. No session exists until the account verifies a first code." — "The hold has no back and no cancel. The enrollment step offers no exit … Switch to `always` deliberately. Every account without MFA stops at the enrollment screen at its next sign-in, **including administrators**."
- The runtime tier: `iam.mfa.type` (`none`/`totp`) and `iam.mfa.enforcement`, changed on Configure → Platform → Settings without a restart.

**What I did:** opened the Security chapter of the settings page (MFA factor type = TOTP, enforcement was "Optional"), set enforcement to **Required**, saved. Verified behaviourally: signed in as Pat (who had skipped enrollment earlier) — the login is now **held at the enrollment screen and the "Skip for now" button is gone**; only "Verify and enable" exists, exactly matching the documented "no back and no cancel". I then completed Pat's enrollment with a generated TOTP code and confirmed the backup-codes hand-off screen appears ("Save these backup codes — each works once"). The setting applied to the next login with no restart, as documented.

**Confusion points:**
1. (minor, wording) The docs' settings table says `preferred` / `always`; the UI's select says **Optional / Required**. The mapping is guessable but the Reference and the UI should agree on the value labels.
2. (minor) The settings page saves section by section; my save sequence produced a mixed flash ("saved … refused … saved") with no indication which section the refusal was about. The effective state was correct, but diagnosing a partial save would be painful.
3. (minor) Reading the effective settings back over the API (`GET /Api/core/SystemSettings`) answers **Forbidden** even for the admin role — the docs say "the same save works from an API call" but never name the read route for a verification check; I verified behaviourally instead.

**Result:** Completed — enforcement set to required, hold-at-enrollment verified on a real un-enrolled account. **Severity:** minor.

---

## Task 14 — As an admin: who changed a booking yesterday, and what?

**Pages visited:** `/admin/history/audit/` (See who did what), `/admin/history/roll-back/` (referenced), plus the two live surfaces: Configure → Audit log and the document History page

**What the docs say (quoted):**
- "Every document answers for its own past on the history route" and "The global log lists every change. Filters ride the bracket form: `GET /Api/Audit?filters[action__eq]=delete&filters[domain__eq]=iam`".
- "Each row shows: Action … Actor — the account or system that made the change … Who — the actor, with a chip that names the cause … the fields that changed."

**What I found on the instance:**
- **The global audit** (Configure → Audit log, "Append-only event log. Every mutation recorded with actor, time, and target state") lists every change with action, document, actor, channel, relative time — including my booking change: "Updated | Main tent 10x15 | Administrator | facet"; my MFA policy change ("Updated | System settings | Administrator | facet"); logins; even the schema migration pass ("Migrated | Main tent 10x15 | system:migration"). 357 mutations so far, paged.
- **The document history** for `BK-2026-0001` answers the "what" precisely: the entry shows "Updated | Booking BK-2026-0001 | v3 | Administrator | via facet · iam.Roles.admin | 2026-11-26 17:08:05" with the field detail "2 set: /status → draft, /dates/start → 2026-12-12" — actor, role, channel, exact timestamp, and the two changed fields with their new values.

**About "yesterday":** this instance has existed for hours, so there *is* no yesterday — the log starts at boot. The surfaces are date-filterable (the audit list carries filters; the document history shows full timestamps), so the same question resolves for any real day. A newcomer on a fresh install learns the honest answer: the log covers the instance's whole life, and "who changed X" is answerable from hour one.

**Confusion points:**
1. **(confusing) The documented API route for the global log is not reachable**: `GET /Api/Audit?…` answers **Forbidden** for the administrator role (both with session cookie and as documented). The UI page reads it fine, so the data is there — but the docs' own example command fails on the shipped default admin. I could not determine why without source.
2. (minor) API logins now interact with the new MFA enforcement (Task 13): `POST /Api/iam/login` answers with `mfa_enroll_required` + a secret instead of a session, and the follow-up `POST /Api/iam/mfa/totp/verify` answers 401 with the cookie. The docs never document the API-side MFA steps, so a developer following the curl transcripts breaks the moment `always` enforcement is on. (My browser session kept working.)
3. (minor) On the global audit list, the DOCUMENT column is empty for login/mfa rows — fine — but a newcomer scanning for "who touched this booking" must switch to the document's own History page for field-level detail; the global list shows the actor but not the field changes. The docs do describe both surfaces clearly.

**Result:** Completed (actor, role, channel, timestamp, and field-level changes identified for the booking; "yesterday" impossible on a fresh install — explained). **Severity:** confusing (audit API route) + minor.

---

## Task 15 — As an admin: how long is history kept, and can I change it?

**Pages visited:** `/admin/history/retention/` (Retention: what is kept), `/admin/history/roll-back/` (linked from it), the Settings UI (Retention chapter)

**What the docs say (quoted):**
- "The full history of every document is kept for **180 days by default**. Older changes fold into one snapshot per document, so you can roll back at most 180 days." — "`mutations.retention_days`, default 180. `0` keeps everything. Older rows fold into one snapshot row per document." — "The history window bounds rollback depth. A rollback target older than the window answers `404`. Widening the window does not bring compacted rows back."
- Change it: edit `config.{env}.yml`, or "pin it at runtime. Open **Configure → Platform → Settings** and set `mutations.retention_days` … A pin applies from the next daily pass." Per-doctype overrides are file-only.

**What I found on the instance:** the Retention chapter of the settings page shows exactly the two windows with their semantics — "History retention: Days of edit history kept per document. Older entries fold into one snapshot. Rollback past the window answers 404. Zero keeps history forever. Empty follows the file — default 180." and "Deleted content retention … default 30" — each with a **Keep forever** toggle. The docs' numbers (180/30) and behaviours match the UI text one for one.

**My answer:** history is kept 180 days by default (the full who/what/when of every change, then folded into one snapshot per document); yes, I can change it — pin `mutations.retention_days` at runtime on the Settings page (applies from the next daily pass, no restart) or set it in the config file; `0` keeps everything forever; per-doctype overrides exist but are file-only; and widening the window cannot resurrect already-compacted history.

**Confusion points:** none — this is the clearest admin page in the set. The only nit: the UI's "Keep forever" toggle is a friendlier face for `0`, but the docs' key table never mentions that mapping.
---

## Task 16 — As an operator: what do you need to back up?

**Pages visited:** `/admin/keep-running/backup-restore/` (Back up and restore), `/admin/keep-running/` (group entry point)

**What the docs say (quoted):**
- "Facet ships no backup feature: no backup command, no scheduled dumps, no point-in-time recovery. Backup and restore are the operator's job, by design."
- "Four things hold state. Lose any one of them and part of the installation is gone for good." — **PostgreSQL** ("every document, every history row, every secret slot, accounts, roles, settings"), **Artifact storage** ("Uploaded files and generated bundles live outside the database, by design"), **Config files** ("`config.{env}.yml`, plus any `.env`"), **Secrets** ("The secret-store master key … Restore a database without the key that sealed it, and every sealed slot stays unreadable — sign-ins fail, webhooks lose their credentials.")
- "Redis is a reaction bus, not a record … Do not spend backup effort on it." — "Use `pg_dump` for logical dumps, `pg_basebackup` … WAL archiving for point-in-time recovery. Facet uses standard PostgreSQL features only."

**My answer:** back up four things — the PostgreSQL volume/data (everything durable lives there), the artifact store (files live outside the DB on purpose), the config files, and the secrets: above all the `FACET_SECRETS_MASTER_KEY` that seals every stored secret (TOTP seeds, API credentials, password hashes), kept "in a place with different failure modes than the database host", plus `JWT_SIGNING_KEY`. Explicitly **not** Redis — it is a reaction bus and self-heals.

**Confusion points:** none. The page's honesty ("Facet ships no backup feature … by design") is exactly what an operator needs up front, the four-item table is complete, and the master-key warning is the kind of thing that otherwise only surfaces during a failed restore. The restore-proof section continues in the same vein.

**Result:** Completed. **Severity:** minor.

---

## Task 17 — As an operator: how do I upgrade, and what happens to running requests?

**Pages visited:** `/admin/keep-running/upgrades/` (Upgrade Facet)

**What the docs say (quoted):**
- "Upgrading Facet is deliberately boring. A release is a new container image, and the entrypoint migrates the schema on boot. An upgrade is pull, restart, and a health check." — steps: pin a release tag (never `latest` in production), read the release's **Deployment notes** in `CHANGELOG.md`, then `docker compose pull` + `up -d`; the boot chain is "render config (when absent) → migrate → seed:core → server", every step idempotent, migrate retries three times; then check `GET /Healthcheck`.
- **Running requests:** "A stop is a signal too. On one signal the backend closes its listeners and sends a close frame to every WebSocket. It waits for in-flight requests, then tears its subsystems down in a fixed order." The stop sequence: traps SIGTERM/SIGINT/SIGHUP, closes listeners → notifies WebSockets → drains in-flight requests → teardown newest-first (cron, jobs, hooks, webhook delivery, … event manager last) → "Every step runs even when an earlier step raises"; a second signal exits at once.
- Operational cautions that land: `stop_grace_period` must exceed the app's 30-second drain bound ("the shipped compose file does not raise it" — default 10 s would cut the drain); migrations are append-only with tested `-- DOWN` sections; take a snapshot before any `migrate:down`.

**My answer:** upgrade = pin the new tag, read Deployment notes, `pull` + `up -d` (the entrypoint migrates on boot), then `GET /Healthcheck`. Running requests are respected: on stop the backend stops accepting, notifies WebSocket clients, waits for in-flight requests (30 s bound), and tears down in a fixed order — nothing is cut mid-request provided the container grace period is set above 30 s.

**Confusion points:** none material. The page even states the releases so far (0.2.0-beta/0.2.1/0.2.2) matching the environment, and is honest about the pre-1.0 breaking-change risk. Rollback needs a database snapshot + `facet migrate:down` — stated plainly.

**Result:** Completed. **Severity:** minor.

---

## Task 18 — The exact config key that sets file storage

**Pages visited:** `/admin/configure/file-storage/` (File storage), `/reference/config-keys/` (cross-check via the site's own text set)

**What the docs say (quoted):**
- File storage page: "Two top-level keys are required: `artifact_base_url` and `artifact_grant_secret`. The boot fails without them." — "The storage adapter wires once per process from the config file." — the example config: `artifact: storage: type: filesystem, directory: /data/store` (or `type: s3, bucket, region, directory`).
- The System settings page confirms the runtime tier is read-only for this: "Any value on `artifact.storage.type` is refused. The storage adapter wires once per process from the file."

**My answer:** the config key is **`artifact.storage`** (nested: `artifact.storage.type` choosing `filesystem` or `s3`, plus `directory`/`bucket`/`region`), with the two required companions `artifact_base_url` and `artifact_grant_secret`. Related keys: `artifact.max_upload_bytes` (default 50 MiB), `artifact.prune_after_days`.

**Confusion points:**
- (minor) The dotted spellings appear in two roles: `artifact.storage.type` as a **runtime settings path** (visible on the Settings page, read-only) and as the nested YAML key in the config file. The docs keep the two tiers clear elsewhere ("file-only" annotations), so this resolves quickly, but a newcomer meeting `artifact.storage.type` on the Settings page first might try to change it there.

**Result:** Completed — exact key found from Discover→Administer→Reference in one pass. **Severity:** minor.

---

## Task 19 — Features Facet does not have that you might expect

**Pages visited:** `/discover/is-it-right-for-you/` ("What Facet does not have"), `/discover/why-facet/` ("What Facet is not"), `/discover/compare/vs-airtable-notion/` ("What Facet does not do (yet)")

**The lists, quoted:**
- Is it right for you? — "We would rather you hear this from us. Each line is checkable in the source: **No built-in reports or charts** … **No workflow engine** (event hooks and webhooks react to single events; there is no engine for multi-step flows or approval chains across domains) … **No prebuilt business modules**: no CRM, accounting, inventory or HR to install … **No public sign-up** … **No mobile app and no hosted version** … **No passkeys** (sign-in is password with MFA, SSO, or API keys) … **No role templates**."
- Why Facet — "Not a public app platform … Not an analytics tool … Not for heavy data loads … Not for several companies at once … Not a hosted service."
- Compare page adds: "There is no template library yet", "no built-in reporting — you export or connect a BI tool through the API", "Facet is in beta".

**My answer (what a newcomer would expect but won't find):**
1. **No dashboards/charts/reports** — lists, tables, boards, calendars only; BI via export/API.
2. **No workflow/approval engine** — single-event hooks and webhooks, no multi-step flows.
3. **No ready-made modules or templates** — no CRM/inventory/HR to install, no template library; you model everything yourself (the assistant helps).
4. **No public/self-service sign-up** — accounts come from invites or SSO only.
5. **No mobile app, no hosted/SaaS option** — self-hosted only, you run the servers.
6. **No passkeys** — password+MFA, SSO, or API keys.
7. **No role templates** — every role's permissions are defined by hand.
8. Also from Why Facet: no multi-company tenancy, no B2C surface, wrong tool for heavy analytics/time-series loads.

**Confusion points:** none — the docs volunteer every gap unprompted (three separate pages, each with "We would rather you hear this from us"), which is exactly the right tone for an evaluator. The only risk is that these lists live under Discover; a buyer who starts at Build might miss them (the compare pages restate most of them, which mitigates this).

**Result:** Completed from Discover alone. **Severity:** minor.

---

## Task 20 — Three glossary lookups: were the definitions enough?

**Pages visited:** `/reference/glossary/`

The three terms I genuinely had to stop for during the test:

1. **Projection** — glossary: "The current version of a document: its content, label, search text, and backlinks. Reads use projections; the log stores [the changes]." Enough? **Yes, barely** — it tells me what it is and how reads work, though the word itself ("projection") is jargon the glossary cannot avoid; the pointer to How documents work closes it. During Task 8 I hit the related term **Re-projection** ("The rebuild of a document's current version after its doctype definition changed") — that one was enough on its own and explained a UI notice I'd seen.
2. **Tombstone** — glossary: "A deleted document Facet still remembers, for history and restore. A tombstone is invisible to lists and search." Enough? **Yes** — two sentences, and it exactly matches what I saw on the live instance (a deleted answer reads 410 Gone, history still shows it) and what the retention page says about pruning content later.
3. **Grant** — glossary: "Explicit consent. An app grant says what an external app may do; a domain grant lets one domain read named resources of another." Enough? **Almost** — the two senses are correctly split and the links point onward, but the sentence doesn't say the *domain* grant is filed by the producer and needs the producer's activation (I only learned that on the domain-isolation deep page when Task 10's import printed "grant ticket filed (inactive — awaiting the producer's acceptance)"). A half-line more in the glossary would have saved that surprise.

Also sampled: **Doctype** ("A typed record type inside a domain, such as `hr.Employee`. Its definition declares the fields, the actions, and the scopes.") — enough; **Mutation** ("One row in the change log: who changed which document, how, when, and why.") — enough.

**My verdict on the glossary:** the entries are short, honest, and cross-linked; two of my three terms were fully sufficient, one (grant) needed a companion page for the activation detail. As a safety net it works — but it is a *reference* section a newcomer reaches late; the Discover pages that first use these words (e.g. "doctype" first appears on the Domains page without a glossary pointer) would benefit from a "term — see the glossary" link at first use.

**Result:** Completed. **Severity:** minor.

---

## Verdict

**What the docs do well.** The Discover tab answers what/why/fit questions honestly (tasks 1–4, 19 all answerable from Discover alone, with the "what we don't have" lists volunteering the gaps). The five big-picture pages are the best-written pages in the set. Admin and operator pages (retention, backup, upgrades, MFA, accounts) are precise, warn about the right traps (master key, stop_grace_period, always-enforcement), and matched the running instance everywhere I could check them. The glossary works. Field tags, row-scope *semantics*, the grants∩roles model, history/undo, bundles, and the audit trail all behaved exactly as documented.

**Where it broke down.**
1. **(blocker) The frozen site is not the production build the docs describe:** search is disabled, every `/<path>.md` twin 404s, and the "Copy as markdown" button is dead — on the very site that advertises those affordances to readers and agents.
2. **(blocker) The shipped example is schema-only.** "The Brightwater Rentals example loaded" has zero documents, zero demo users (Ravi's documented password fails), zero example roles (warehouse/sales/manager absent, `my_clients` scope undefined). Tutorials 4 and 5 and tasks 6/7/12/14 could only run after I hand-built the demo's missing people, roles, and data. The docs never describe what "loaded" should mean, nor give a fallback for a fresh instance.
3. **(blocker) Publishing a changed structure over a live domain silently fails in the Builder UI:** the API 409s with "resend with overwrite:true", the dialog offers no overwrite control, and no error is shown. I completed the publish via the API.
4. **(confusing) The domain-editors gate:** a live domain refuses "Edit existing" until the account is on the domain's Editors tab — which is empty even for the Administrator on seeded domains; no authoring page explains it.
5. **(confusing) Docs/runtime contradictions around schema changes:** "Add a field → safe at the same version" vs the publish gate demanding a version bump + Lua migration; the Check tab's phantom "no display_name" warnings; the reference-picker searching ids, not labels; undocumented API-side MFA steps; `GET /Api/Audit` Forbidden for the admin role.

**Counts:** blockers: 3 (site build, example data, silent publish-overwrite). Confusing: ~9 across tasks (counted per confusion point above). Minor: the rest. No task was left unanswerable.

**Pass criteria:**
- Tasks 1–4 and 19 answered correctly from Discover: **pass** (with two minor frictions: one guessed URL, and the "small team, simple collaboration" verdict living on the Compare page rather than the fits page).
- Tasks 5–18 completed: **pass with caveats** — all 14 completed on the instance or via the docs' own API transcripts; tutorial 3's watcher half and tutorial 4's app-code steps were out of reach of the frozen environment (noted per task), and three tasks needed undocumented API workarounds (publish overwrite, audit read, MFA-after-enforcement).
- No blocker: **not held** — the three blockers above are all reachable by a newcomer following the docs as written.


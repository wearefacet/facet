# App Configure

The Apps configuration surface brings the `app.App` document type (a regular Facet document managed through the standard Document API) into the Configure shell. It exposes a list with preset cards, a creation wizard (setup → permissions → review → credentials), a detail page with three tabs, and a plain-language permissions picker shared between the wizard and the grants tab.

`app.App` is documented at the backend level in `data/seeds/app.App/definition.yml` and `spec/app/registration_spec.cr`. This doc describes only the frontend surface.

## Source files

- `frontend/src/routes/Configure/apps/+page.ts` + `+page.svelte` — apps list. Renders preset cards when the list is empty; one row per app otherwise.
- `frontend/src/routes/Configure/apps/new/+layout.ts` + `+layout.svelte` — wizard shell (thin stepper); the bare `/Configure/apps/new` route redirects to `setup` via `+page.ts`. The layout load resolves the OAuth issuer base from `/.well-known/oauth-authorization-server` and the current account from the parent layout's `data.account`, threading both down as `issuerBase` and `currentAccount`.
- `frontend/src/routes/Configure/apps/new/{setup,permissions,review,credentials}/+page.svelte` — wizard step pages.
- `frontend/src/routes/Configure/apps/[slug]/+layout.ts` + `+layout.svelte` — detail shell (title + tab strip).
- `frontend/src/routes/Configure/apps/[slug]/{overview,grants,settings}/+page.svelte` — detail tabs; `overview/+page.ts` loads the deployment history.
- `frontend/src/routes/Configure/apps/[slug]/deploy/+page.svelte` — deploy flow: folder / file pickers → one multipart `POST /Api/app/:id/deploy`.
- `frontend/src/lib/app/deployments.ts` — thin client: `listDeployments` (Document API list), `activateDeployment` (PATCH `active_deployment`), `uploadDeployment` (multipart deploy route).
- `frontend/src/lib/components/features/apps/SetupForm.svelte` + `.stories.svelte` — wizard step 1 body: identity fields, the live sign-in address, and the origins/URIs editors. The page owns the save and the navigation.
- `frontend/src/lib/components/features/apps/PermissionsForm.svelte` + `.stories.svelte` — wizard step 2 body: the grants editor plus the service-role picker for backend apps. The page owns the save and the navigation.
- `frontend/src/lib/components/features/apps/ReviewPanel.svelte` + `.stories.svelte` — wizard step 3 body: the done/blocking checklist and the consent preview. The page owns the publish call and the navigation.
- `frontend/src/lib/components/features/apps/CredentialsSuccess.svelte` + `.stories.svelte` — wizard credentials success screen: the read-only identity card, the PKCE notice or the one-time API-key issue panel, and the client snippets. The page owns the navigation hand-off.
- `frontend/src/lib/components/features/configure/AppGrantsEditor.svelte` + `.stories.svelte` — the shared plain-language grants picker (segmented control, nested children with inheritance, materialise-on-save).
- `frontend/src/lib/components/features/apps/CredentialsPanel.svelte` + `.stories.svelte` — the Overview tab body: identity, service identity or origins, deployment panel, lifecycle. The route page keeps the load, the mutations, and the navigation; the panel renders from props and reports actions through callbacks.
- `frontend/src/lib/components/features/apps/AppSettingsForm.svelte` + `.stories.svelte` — the Settings tab body: read-only identity, editable fields (one flat PATCH per section, the serving host among them), the service-role picker and API-key panel for confidential apps, and the danger zone. The form owns the draft; the page owns persistence.
- `frontend/src/lib/components/features/apps/DeployPanel.svelte` + `.stories.svelte` — the deploy flow body: pickers, path manifest, and upload options. The page sends one multipart `POST /Api/app/:id/deploy`.
- `frontend/src/lib/components/primitives/forms/StringListEditor.svelte` — editable chips list for `redirect_uris`, `allowed_origins`, `compatible_roles`.
- `frontend/src/lib/app/appGrantsMapping.ts` + `.spec.ts` — pure helpers: plain-level ↔ `actions[]` mapping, inheritance resolution, clamping, materialisation, and the grouped consent summary.
- `frontend/src/lib/app/appValidation.ts` + `.spec.ts` — pure helpers: slug derivation, origin/redirect URI validation, sign-in address derivation, client snippet builder, app-host validation (`validateHostname`, mirrors the backend hook rule) and deployment path validation (`validateDeployPath`, mirrors the deploy route's safe-path rule).
- `frontend/src/lib/app/appTypes.ts` — `AppContent`, `AppGrant`, `AppGrantAction`, `DoctypeCatalogueEntry`, `DeploymentContent`, `DeploymentFileEntry` types.
- `frontend/src/lib/doctypeCatalogue.ts` + `.spec.ts` — loads the live `core.DocType` rows into the catalogue entry shape the editor consumes (including `pluralLabel`, `sensitive`, `parentTarget`); doctypes of a draft domain are excluded.

## Routes

| Surface                   | Route                                       |
| ------------------------- | ------------------------------------------- |
| Apps list                 | `/Configure/apps`                           |
| Wizard — setup            | `/Configure/apps/new/setup?preset=<preset>` |
| Wizard — permissions      | `/Configure/apps/new/permissions?app=<id>`  |
| Wizard — review           | `/Configure/apps/new/review?app=<id>`       |
| Wizard — credentials      | `/Configure/apps/new/credentials?app=<id>`  |
| App detail — redirect     | `/Configure/apps/[slug]` → `./overview`     |
| App detail — Overview tab | `/Configure/apps/[slug]/overview`           |
| App detail — Deploy flow  | `/Configure/apps/[slug]/deploy`             |
| App detail — Grants tab   | `/Configure/apps/[slug]/grants`             |
| App detail — Settings tab | `/Configure/apps/[slug]/settings`           |

Static segments (`setup`, `permissions`, `review`, `credentials`, `overview`, `grants`, `settings`) avoid colliding with the dynamic `[slug]`. The detail layout resolves `slug → id` once via `slug__eq`, then reads the document; the resolved document and doctype catalogue are passed down via layout data so tab switches do not refetch.

The wizard threads the in-progress document id through the `?app=<id>` query parameter, appended after the setup step creates the draft (with `replaceState` so it does not pollute history). The draft document is the model — each step reads the current document by id, edits locally, and PATCHes on Continue. A Back navigation re-reads the persisted draft, so the wizard is always consistent with the document.

## Wizard flow

The wizard is a thin horizontal stepper (`1 Set it up › 2 Permissions › 3 Review › 4 Credentials`).

1. **Setup** (`setup`) — display name first, with the slug auto-derived via `toSlug` until the user clicks "Edit". Owner defaults to the current account. Both client types edit the allowed origins and redirect URIs (a `confidential` app signs in through a browser too). The `?preset=` query param (`external` | `backend`, with legacy `confidential` aliasing to `backend`) seeds the client type.
2. **Permissions** (`permissions`) — the `AppGrantsEditor` in `wizard` mode. For a backend app, a service-role picker (`ReferencePicker` on `iam.Roles`) sits above the grants editor: the grants are the ceiling, the role is the floor, and effective permission is grant ∩ role. Every grant target is concrete by construction — the editor builds entries from the doctype catalogue, and the backend refuses the wildcard form at authoring time. When the picked role misses a required grant action, a non-blocking warning names the gap ("missing: update on fin.Invoice"); the check is the pure port in `lib/authorization/grantUsable.ts` (mirrors `GrantResolver.role_usable?`, including the `write` → `create`+`update` expansion and the `except` carve-out rule) and never blocks Continue — roles and grants can drift after setup, so a hard gate here would be a false guarantee. The warning stays hidden while the role's permissions are still loading. Continue PATCHes `grants` and `service_role_id` together and blocks while the role is empty.
3. **Review** (`review`) — two-tier checklist (required vs. optional), per-row Edit links back to the step that sets each item, and the grouped consent preview. A backend app swaps the origins/redirects items for a blocking "Service role" item. The Publish button is disabled while any required item is incomplete, with the reason inline. Publish PATCHes `status: 'active'` and navigates to the credentials screen.
4. **Credentials** (`credentials`) — the post-publish success screen. For a `public` app: the `client_id`, the sign-in address, the discovery document URL, a copy-pasteable TypeScript snippet built by `buildClientSnippet`, and a "No client secret" panel explaining PKCE + DPoP. For a `backend` app: a "Generate API key" flow instead — the key is issued via `POST /Api/app/:id/api-key`, revealed once with a copy button, confirmed with "I stored it", and a `curl` snippet built by `buildCurlSnippet` replaces the browser-flow snippet. The "Test sign-in" action is a follow-up; v1 ships a "Discovery document" secondary link.

## Empty state presets

When the apps list is empty, the list page renders two live preset cards instead of a bare "no apps" message:

- **Web app you host** (`preset=external`) — `client_type: public`, PKCE + DPoP.
- **Backend app** (`preset=backend`) — `client_type: confidential`, API key.

Clicking a preset navigates to `/Configure/apps/new/setup?preset=<preset>`.

## Deployment (Part C)

Facet serves an app's static build at the app's own host; the deployment surface is backend-documented in `doc/backend/app-system.md` → Deployment serving. The frontend pieces:

- **Overview tab — Deployment panel.** Shown for managed apps (the app carries `host` or `active_deployment`). It shows the active build (revision, note, deployed date, file count, SPA flag, host), a history list with per-row **Activate** (activating an older revision is the rollback), and a **Deploy a build** button that opens the deploy flow. The history comes from the tab's own load (`overview/+page.ts`) via `listDeployments`; a failed read degrades to an empty history.
- **CLI notice.** Both the panel and the deploy flow carry a notice that deploys normally run from the **facet CLI** — not yet released — with a placeholder button to the future deployment guide (inert until the docs exist; a real `<button>`, not an `href="#"` link). The dashboard flow is the fallback until the CLI ships.
- **Deploy flow (`deploy/+page.svelte`).** A build-folder picker (`webkitdirectory`, set imperatively via a `use:` action — non-standard attribute) and a loose-files picker feed a de-duplicated path manifest validated by `validateDeployPath`. Note, SPA fallback, and activate toggles ride in `$content`; files go as `files[<i>].file` parts. One spinner — per-file progress is out of scope. Success invalidates and returns to the detail page.
- **Apps list badge.** The list load also reads `app.Deployment` once and maps each app to its highest deployed revision; managed apps show an `r<n>` badge. The read is optional decoration — when the Deployment doctype is unreachable the list renders without badges.

- **Serving host editor.** The Settings tab's Serving section edits `host`: a text input validated client-side by `validateHostname` (the mirror of the backend hook rule; the hook stays the authority and its 422s surface through the page's error banner), a Save behind the `update` permission, and a `no_asset` interplay — the hook refuses a host on a no-asset app, so the input sits disabled with a helper naming the reason. Saving an empty input clears the field with a `null` patch value (JSON Merge Patch removal). The wizard collects no host; the Overview surface shows the saved host read-only.

The wizard's "Facet serves this app" host input (origin + redirect pinning to `https://<host>`) remains unbuilt; `validateHostname` backs the Settings editor today.

## AppGrantsEditor

The shared grants picker. Props only — no context:

```ts
type Props = {
  grants: AppGrant[]; // $bindable; mutated in place
  doctypeCatalogue: DoctypeCatalogueEntry[];
  mode: "wizard" | "edit"; // 'wizard' shows the header explainer
  onchange?: (grants: AppGrant[]) => void; // receives the materialised grants
};
```

The parent owns the `grants` `$state` array and binds it. The editor mutates the array in place (add/remove grant entries, change the access level, flip `required`). Per the workflow doc's deep-mutation rule, the mutation handlers and the derived summary live in the same component so the summary re-renders from the same scope as the mutations.

The editor renders a **domain segmented rail** with grant counts per domain, a **bulk-set row** for the active domain, a **segmented control** (None / Read / Write / Full) per doctype, a **required-flag row** under the segmented control (see below), nested **children under their parent** with inherit-by-default + explicit override + clamp, and **named actions as toggle-pills** that only render when the effective level is above None. A lock icon marks sensitive doctypes.

### Required flags on core actions

The level owns **membership**; each granted action owns its own `required` flag. When a doctype's level is above None, a row titled "Role must have at setup" lists the level's actions as pills (Read, Create and edit, Delete), each with a Required/Optional toggle. Default is optional — no grant changes shape until an operator flips a toggle. A required action makes the setup-time usability check (`roleUsable` / `missingRequiredActions`) name the gap when the picked service role lacks it, gates OAuth consent and key issuance on the backend, and disables the app's launcher card for roles that miss it.

The flags shown are the **effective** ones (`effectiveRequireds`): the doctype's own entry when it has one, otherwise the nearest ancestor grant's — the same walk the displayed level uses. Flipping a toggle on an inherited child materialises its explicit entry first (override-on-touch, like the level segments). Changing a level preserves the flags the picker displayed; `materialiseInherited` copies the source grant's flags into the entries it writes.

The doctype catalogue is loaded by `loadDoctypeCatalogue` from `core.DocType`. The list endpoint returns the full document content (including the `actions` dictionary, `plural_label`, `sensitive`, `member_of`), so a single call surfaces every doctype's named actions, its plural noun, its sensitivity, and its parent for inheritance. The catalogue is loaded once in the wizard layout and the detail layout so neither refetches on tab switches.

**Draft domains are excluded.** The loader also lists `core.Domain` and drops every doctype whose `domain` names a document with `draft: true`. A draft domain is schema authoring in progress (the builder), so its doctypes can be renamed, dropped, or never published — a grant naming one could not be honoured. The domain rail therefore shows live domains only, and the grants editor offers no draft-domain doctype.

### Inheritance and materialisation

Inheritance is a **frontend editor behaviour**, not a backend grant-shape change. A child doctype with no explicit grant inherits its parent's effective level for display. The backend `RBAC::GrantResolver` does **not** implement inheritance: a child with no grant entry has no effective permission through the app token, even if the parent has `write`.

To keep the displayed permission aligned with the issued token, the editor calls `materialiseInherited` before every `onchange` emission. `materialiseInherited` writes an explicit grant entry for every child that displays a non-`none` level — copying the parent's effective level and its required flags — unless the child already has its own explicit grant. The materialised grants array is spliced into the bound `grants` `$state` in place, so the parent's bound state (what it persists) always matches the displayed levels.

The clamp is enforced by `clampChildLevel`: a child's level can never exceed its parent's effective level. Segments above the parent's ceiling are disabled in the UI. When the parent's level drops, `clearChildrenExceedingParent` removes explicit child grants that now exceed the parent (clear-to-inherited, not clamp-and-keep-explicit).

## Grants mapping

The plain-language access levels the picker exposes map to raw `actions[]` arrays:

| Plain level | `actions` produced                                       |
| ----------- | -------------------------------------------------------- |
| None        | (no grant entry)                                         |
| Read        | `[{name:"read", required:?}]`                            |
| Write       | `[{name:"read",…}, {name:"write",…}]`                    |
| Full        | `[{name:"read",…}, {name:"write",…}, {name:"delete",…}]` |

| Plain level | `actions` produced                                       |
| ----------- | -------------------------------------------------------- |
| None        | (no grant entry)                                         |
| Read        | `[{name:"read", required:?}]`                            |
| Write       | `[{name:"read",…}, {name:"write",…}]`                    |
| Full        | `[{name:"read",…}, {name:"write",…}, {name:"delete",…}]` |

The `required:?` flags come from the required-flag row (see above); the editor writes `false` for every action until the operator flips a toggle. `write` is the alias that covers create and update, so no separate "add" level is needed. The levels are ordered `none < read < write < full`; this ordering is the basis for the parent/child clamp. Pure helpers in `appGrantsMapping.ts`:

| Function                                                        | Purpose                                                                                               |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `levelToActions(level, requireds)`                              | Builds the `actions[]` for a plain level and caller-supplied required flags.                          |
| `levelActionNames(level)`                                       | The action names a level grants, in canonical order (read, write, delete).                            |
| `coreActionVerb(name)`                                          | The consent verb for a core action name ("Read", "Create and edit", "Delete").                        |
| `effectiveRequireds(grants, target, catalogue)`                 | The required flags backing a doctype's effective level (own entry, else the nearest ancestor's).      |
| `actionsToLevel(actions)`                                       | Recovers the plain level from a stored `actions[]`, classifying by the read/write/delete subset only. |
| `resolveEffectiveLevel(grants, target, catalogue)`              | Resolves a doctype's effective level, walking the parent chain for inheritance.                       |
| `clampChildLevel(desired, parentLevel)`                         | Returns `min(desired, parentLevel)` so a child never exceeds its parent.                              |
| `clearChildrenExceedingParent(grants, parentTarget, catalogue)` | Removes explicit child grants that exceed the parent after a drop.                                    |
| `materialiseInherited(grants, catalogue)`                       | Writes inherited levels as explicit grant entries before save (the editor's save-time contract).      |
| `summarizeGrants(grants, catalogue)`                            | Groups grants into `ConsentGroup[]` (verb + noun list per group) for the consent preview.             |
| `anySensitiveGranted(grants, catalogue)`                        | Returns true when at least one granted doctype is flagged sensitive.                                  |
| `fallbackPlural(target)`                                        | Naive English pluraliser used as a fallback when a doctype has no `plural_label`.                     |

## Validation and derivation helpers

Pure helpers in `appValidation.ts`:

| Function                                      | Purpose                                                                               |
| --------------------------------------------- | ------------------------------------------------------------------------------------- |
| `toSlug(displayName)`                         | Derives a URL-safe slug from a display name (lowercase, hyphens, `[a-z0-9-]`).        |
| `validateOrigin(value)`                       | Returns `null` if `value` is a valid bare origin (http/https, no path/query).         |
| `validateRedirectUri(value)`                  | Returns `null` if `value` is a valid redirect URI (https, or localhost, no fragment). |
| `redirectOriginAllowed(redirectUri, origins)` | Returns true when the redirect URI's origin is in the allowed-origins list.           |
| `deriveSignInAddress(issuerBase, slug)`       | Returns `${issuerBase}/auth/${slug}` — the public sign-in address.                    |
| `discoveryPath()`                             | Returns `/.well-known/oauth-authorization-server` (RFC 8414).                         |
| `buildClientSnippet(app, issuerBase)`         | Builds the copy-pasteable TypeScript `createClient({...})` snippet.                   |
| `grantsToScopes(grants)`                      | Converts the stored grants array into flat `domain.doctype:action` scope strings.     |

The mapping and validation helpers are pure (no Svelte, no state) and are unit-tested in `appGrantsMapping.spec.ts` and `appValidation.spec.ts` (Vitest `server` project). The editor's behaviour is covered by Storybook `play` functions in `AppGrantsEditor.stories.svelte`.

## Doctype catalogue fields

`DoctypeCatalogueEntry` (in `appTypes.ts`) carries the fields the picker reads:

| Field          | Source on `core.DocType`                  | Used for                                                        |
| -------------- | ----------------------------------------- | --------------------------------------------------------------- |
| `target`       | `${domain}.${doctype}`                    | Grant key; selection identity.                                  |
| `label`        | `doctype`                                 | \_card label.                                                   |
| `description`  | `description`                             | card sub-label.                                                 |
| `domain`       | `domain`                                  | rail segment grouping.                                          |
| `namedActions` | `actions`                                 | "Extra abilities" toggle-pills.                                 |
| `pluralLabel`  | `plural_label` (fallback to naive plural) | consent copy noun ("contacts", "company memberships").          |
| `sensitive`    | `sensitive`                               | lock icon + "access is logged" footnote on the consent preview. |
| `parentTarget` | `member_of` (qualified)                   | nested children + inheritance walk.                             |

`plural_label` and `sensitive` are optional fields added to the `core.DocType` definition; `loadDoctypeCatalogue` fills `pluralLabel` with a fallback so the field is always present on a loaded catalogue.

## Permission gating

Every Create / Activate / Disable / Re-enable / Delete / Save affordance is gated with `can('app.App', <action>)` or the declarative `<Can>` component. The list and detail pages listen for `facet:permissions-update` and invalidate so the gating re-evaluates when the active role changes. `can()` is a UI hint only — the backend `WriteEnforcer` re-checks every action.

## Quirks

- The wizard shell is URL-driven; the in-progress id is in the query string, not in `sessionStorage`. Refreshing step 2+ without an `app` param is an error — the layout returns `400 No in-progress app`.
- The `slug` input sanitises on input (lowercase, `^[a-z0-9-]+$`) using the workflow doc's plain-`<input>`-with-`oninput` pattern; `bind:value` cannot filter keystrokes. The slug auto-derives from the display name until the user clicks "Edit".
- The setup step sends `slug` on create only. A loaded draft (back-navigation from a later step, e.g. the review checklist's Edit link) renders the slug input disabled, and the Continue PATCH never carries the key — the `app.App` update hook rejects any patch that includes it (`doc/backend/app-system.md` → `slug` immutability).
- The consent screen preview on the review step is built from the document via `summarizeGrants` (grouped verbs). Wiring it to the live `/OAuth/authorize` rendering is a follow-up.
- The "Test sign-in" button on the credentials screen is a follow-up; v1 ships a "Discovery document" secondary link instead.
- `compatible_roles` editing uses `StringListEditor` as a qualified-role-id text list (validator requires a `.`); upgrade to a real roles picker is a follow-up once the IAM roles list endpoint is wired.
- The OAuth issuer base is fetched once in the wizard layout from `/.well-known/oauth-authorization-server` (the `issuer` field). If the discovery endpoint is unreachable, `issuerBase` falls back to the empty string and the derived sign-in address panel is hidden.

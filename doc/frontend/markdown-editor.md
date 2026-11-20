# Markdown editor

The markdown editing surface. It gives users three ways to work with the same markdown source: a readonly preview, a WYSIWYG editor, and a raw markdown source editor — the first two rendered by the same engine. Two components use it: the standalone `Markdown` display component and the `input-longtext` form node.

## Source files

```
frontend/src/lib/
├── artifacts.ts               # Artifact upload + URN helpers
├── mentions.ts                # Account URN helpers + the iam.Account list default
├── docrefs.ts                 # Document URN helpers + doctype list/search defaults
├── referenceSearch.ts         # Picker search shaping, debounce/sequence dispatch
└── components/
    ├── primitives/content/
    │   ├── Milkdown.svelte         # Svelte 5 wrapper around @milkdown/crepe (WYSIWYG)
    │   ├── Markdown.svelte         # Segmented Preview / Write / Markdown + expand overlay
    │   ├── ref-chip.ts             # The ref_chip inline atom node (mention + docref chips)
    │   ├── mermaid-fence.ts        # The `code_block` node view that renders mermaid fences
    │   ├── MermaidDiagram.svelte   # Lazy mermaid renderer (shared with the chat renderer)
    │   ├── markdown-normalize.ts   # Editor-output normalization (empty-paragraph convention)
    │   └── markdown-source.ts      # Shared CodeMirror setup for the raw source editor
    └── features/document-view/
        └── DvtInputLongtext.svelte # Field node composing the Markdown primitive
```

The editor engine is [`@milkdown/crepe`](https://milkdown.dev) (ProseMirror-based, MIT). Milkdown has no Svelte binding, so `Milkdown.svelte` is the project's own thin wrapper — do not add a second wrapper elsewhere.

`Markdown.svelte` is the application's single markdown editing surface: it owns the editors, the upload status display, and the expand overlay. The longtext field node composes it — do not mount `Milkdown.svelte`, the CodeMirror source editor, or a second toolbar anywhere else.

One engine renders every markdown surface: preview and readonly mode mount the same Milkdown editor with `readonly` (empty content shows the `empty` snippet instead), write mode mounts it editable. There is no static markdown-to-HTML renderer in the editing path — preview and Write cannot drift apart. Chat bubbles use their own readonly renderer (`features/chat/markdown-renderer.ts`, marked + allowlist + streaming) and are out of scope here.

Typography: the wrapper's theme rules (heading scale, block styles) are the single prose definition — there is no mirror stylesheet to keep in sync.

Known engine limits in readonly/preview:

- A bare `urn:facet:artifact:<id>` mention (not wrapped in a link) renders as plain text — the editor is a ProseMirror document, not a string rewriter. The editor always inserts proper links, so hand-typed bare URNs are the only way to hit this.
- The editor DOM is created client-side in `onMount`; server-rendered HTML shows an empty surface until hydration.

## Artifacts in longtext

Files dropped or pasted into the WYSIWYG editor upload to the standalone `POST /Api/core/artifacts` route (`doc/backend/artifact.md` → Standalone upload) and reference the stored artifact inline as `urn:facet:artifact:<id>`. Files are **never inlined** as `data:`/`blob:` URLs — Crepe's built-in fallback would inline dropped images as ephemeral `blob:` URLs, so the wrapper always installs an uploader (its own `onupload` prop when given, the default artifact upload otherwise).

The split of duties per file type:

| Event content      | Handled by                                | Inserted markdown                     |
| ------------------ | ----------------------------------------- | ------------------------------------- |
| Images only        | Crepe's uploader (keeps drop coordinates) | `![](urn:facet:artifact:<id>)`        |
| Any non-image file | `Milkdown.svelte` capture handler         | `[filename](urn:facet:artifact:<id>)` |

On save, `Document::ArtifactRefs` extracts the URNs from the longtext into `artifact_references` rows so the artifact survives prune.

Display contract — the URN is the source of truth; only DOM rendering resolves it, to the cookie-auth download gateway (`GET /Api/core/artifacts/:id/download`), which mints a fresh grant per request. All of it lives in the editor DOM:

- Image position renders as an `<img>` whose src Crepe's `proxyDomURL` resolves through the gateway.
- Link position renders as a **capsule** (`.md-artifact-capsule-link`, a pill labelled by the link text) via an inline decoration; the decoration carries `data-artifact-id`.
- In edit mode, clicking a capsule places the caret (the URN never becomes an href — Milkdown's link mark sanitizes unknown schemes to `href=""`). In readonly mode, a click delegate on the wrapper opens the download gateway in a new tab.
- Bare mentions (a URN not in link syntax) render as plain text — see the engine limits above.

`$lib/artifacts.ts` owns the upload + URN halves of the contract: `uploadArtifactAsUrn` / `postArtifact` (upload), `parseArtifactUrn` / `artifactUrn` / `artifactDownloadUrl` / `resolveArtifactUrl` (URN helpers).

## Mentions and references

One trigger opens one picker in every markdown surface: `@` (primary), `[[` (alias), and the `/` slash menu's "Reference a document…" command (the launcher — the Crepe slash menu cannot host the flow, block-start only, but it can open the same picker after clearing the `/…` text). A pick inserts a markdown link whose URL is the target's canonical colon-form URN; rendering turns the link into a chip with a live label. The producer side — the `comment_mention` notification — lives in [`backend/notifications.md`](../backend/notifications.md).

Trigger rules (a `handleTextInput` prop on the ProseMirror view):

- `@` opens the picker only at the start of a block, after whitespace, or after opening punctuation (`(`, `[`, quotes). Inside a word (an email address) it never triggers, and neither does a glyph typed inside code content.
- `[[` opens the same picker; a pick swallows both brackets.
- The trigger glyph stays in the document — on dismissal (`Esc`, click-away) the typed text stays literal. The picker never deletes user input; a pick replaces the range from the trigger glyph to the caret.
- `#` is not a trigger — at the start of a line `# ` is the heading input rule.

Picker states — `empty → domain | all | scoped`, one popup rendered through Svelte (`{#if pickerOpen}`), positioned fixed from `coordsAtPos` and clamped to the editor bounds:

| State    | Entered by                                                     | Shows                                                                                                                                                                                                                                                                                  |
| -------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `empty`  | trigger typed, no query                                        | Recents of the current domain + "Filter by type" (readable doctypes). No People group here — accounts need a query                                                                                                                                                                     |
| `domain` | a query typed, `domain` prop set                               | One call to `GET /Api/{domain}/search` (server-side fan-out — RBAC and searchability enforced there), the pinned People group (a dedicated `iam.Account` list), groups with icons/colours, a "more in ‹label›" row at the per-doctype cap, and the "Search all domains" escalation row |
| `all`    | the escalation row, or `Tab`                                   | One call to `GET /Api/search`, an "All domains" scope chip; Backspace on an empty query backs out                                                                                                                                                                                      |
| `scoped` | "Filter by type", a "more in" row, or `Tab` on a doctype label | One doctype list (`items: 25`), browsable with an empty query, scope chip; Backspace on an empty query backs out                                                                                                                                                                       |

Keyboard: `↑`/`↓` move the selection, `Enter` picks, `Tab` scopes/escalates, `Esc` and click-away close with the literal text kept. Backspace on an empty query in `all`/`scoped` backs out one level.

The data layer is injectable: `Markdown.svelte` / `Milkdown.svelte` take `sources?: PickerSources` (the `onupload` precedent — prop override = stories, default = the real services in `mentions.ts` / `docrefs.ts` / `referenceSearch.ts`). `referenceSearch.ts` is a pure shaping layer: `shapePickerSearch` (root collapse, group-per-doctype, account lift-out, active domain first, `atCap` flag at 5 rows), `createQueryDispatcher` (debounce + sequence — stale responses discarded), and `fetchPickerSearch`. Every hit inherits its group's `domain`/`doctype` — the search contract carries them at group level only — and a group without both drops its hits. `resolveChipLabel` resolves one chip label with the status kinds below.

Chips — the `ref_chip` inline atom node (`ref-chip.ts`), one node for both kinds — the kind derives from the URN (an `iam.Account` URN renders the mention chip, any other document URN the docref chip):

- The stored markdown does not change — a chip is still `[@Label](urn:facet:…)`. The node only changes the in-editor representation: one atom node, one position boundary, no hidden text. `parseMarkdown` claims mdast `link` nodes whose URL is a chip-shaped `urn:facet:` URN (every node spec beats every mark spec in the transformer, so the commonmark link mark never sees them); `toMarkdown` emits the same link back — byte-compatible with the stored form. Artifact URNs and state-pinned URNs (`…?state=…`) are not chips — they keep their own rendering (capsule decoration / plain link).
- The chip label is **live**: resolved through `show()` per URN, cached per editor instance, four states — ok (live title), deleted 404/410 (stored text, struck through), forbidden 403 ("Restricted document" — the stored title may leak information to a viewer who lost access), unknown/unresolvable (stored text, neutral style). An empty stored label falls back to the URN for display; the stored label stays as-is. A resolution (or a doctype-tint load) reaches the node views through the component's `RefChipStore` pub-sub.
- The DOM contract is unchanged: `.md-mention-chip` / `.md-docref-chip`, `.md-chip-avatar` / `.md-chip-dot`, `.md-chip-label`, `data-account-id` / `data-doc-uri`, and the `md-chip-{deleted,forbidden,unknown}` state classes.
- Click contract — edit mode: a chip click creates a `NodeSelection` (ProseMirror's default for selectable atoms); typing replaces the chip, Backspace removes it whole. It never opens the QuickView. Preview/readonly: a chip click emits `onReferenceClick({ domain, doctype, id })` parsed from the href; the QuickView drawer opens when a host wired the handler, and the chip stays static without one. Deleted/forbidden targets still emit — the drawer renders its tombstone (410 + restore) and error cards. Chips are no longer link marks, so Crepe's link tooltip never fires on them (no suppression needed).

Paste-to-chip: pasting an exact `/{domain}/{Doctype}/{id}` URL resolves the document and inserts a reference chip; a failure inserts the literal URL. A plain-text paste (`Ctrl/Cmd+Shift+V`) keeps the URL — the intent rides on the modifier keys of the keydown preceding the paste event, which browsers do not surface on the event itself.

Editor-value sync, one rule: the wrapper pushes an externally changed `value` into the editor only when it differs from the markdown the editor last reported outward (the debounced `markdownUpdated` emission, normalized). It never compares against the live document — Milkdown's serialization is not a fixed point of parse∘serialize (a doc-based compare fires on every mount), and the emission is debounced at 200 ms, so in-flight typing always looks like drift and a doc-based compare would clobber it. Stored link text is never refreshed from the live title (the chip always shows the live label; the stored text only matters for plain-text renderers).

## Diagrams

A `longtext` field can hold a ` ```mermaid ` fenced block, and every reader sees the rendered graph. The stored markdown is a plain fenced code block — no schema, no stored-form change.

- **Parsing.** Crepe's commonmark preset parses the fence into a `code_block` node with `language: "mermaid"`, and serializes it back as the same fence. A round-trip is byte-stable, so the editor-value sync sees no drift.
- **The node view.** `mermaid-fence.ts` registers a `code_block` node-view factory in `Milkdown.svelte` beside `createRefChipPlugins`. A non-mermaid fence returns `null` and keeps the default code-block rendering; a mermaid fence gets one of two views:

| Mode               | View             | DOM                                                                                         |
| ------------------ | ---------------- | ------------------------------------------------------------------------------------------- |
| Readonly (preview) | Diagram only     | `.md-mermaid` — no `contentDOM`, the block is a leaf                                        |
| Edit (write)       | Source + diagram | `.md-mermaid-source` (the `contentDOM`, editable) above `.md-mermaid-preview` (the diagram) |

- **Re-render.** `update` compares the node and re-renders the preview 400 ms after the last change (`RENDER_DEBOUNCE_MS`) — mermaid renders are too costly per keystroke. A language change returns `false`, so ProseMirror re-creates the view and the default code-block rendering comes back.
- **Lazy load.** `MermaidDiagram.svelte` (in `primitives/content/`, shared with the chat renderer) loads the `mermaid` chunk itself. A document without a mermaid fence never builds the component; the chunk loads when the first diagram mounts.
- **Errors.** A parse failure renders the component's error card inside the node; the source stays editable above it.
- **Source mode.** The raw markdown editor (`markdown` toggle) shows the fence as text — diagrams never render there.

## `Markdown.svelte`

Segmented control with three modes, plus a fullscreen expand overlay that mirrors `CodeEditor`:

| Mode       | Rendered by         | Purpose                                                        |
| ---------- | ------------------- | -------------------------------------------------------------- |
| `preview`  | `Milkdown` readonly | Read the rendered document (URNs resolved to gateway/capsules) |
| `write`    | `Milkdown`          | WYSIWYG editing for everyday use                               |
| `markdown` | CodeMirror          | Raw markdown source for advanced users                         |

Public props: `value` (controlled source; omit for uncontrolled use), `defaultValue`, `mode` (initial mode, default `preview`), `readonly`, `bare` (no border/background box — including the body and the editor DOM, which otherwise paint their own surface colour; for embedding in a host that draws its own field box), `placeholder`, `expanded` (two-way bindable), `onchange` (markdown source on every update), `empty` snippet, `uploadFile` (injectable artifact uploader for stories), `onReferenceClick` (chip click handler for readonly surfaces — forwarded to the editor in both modes; edit mode never calls it), `domain` (the current domain segment — scopes the `@` reference picker; `''` on global pages), `sources` (injectable picker/chip data bundle for stories — see Mentions and references).

`readonly` renders the preview only, sized to its content (no editor min-height). Inline there is no toolbar — the fullscreen expand affordance is a small button in the top-right corner, revealed on hover or keyboard focus, so a readonly preview costs no vertical space (the comment sidecar embeds it this way). The expanded overlay keeps a slim bar with the collapse button.

```svelte
<Markdown value={src} onchange={(v) => (src = v)} />
```

## `Milkdown.svelte`

Wraps one `Crepe` editor instance. Created in `onMount`, destroyed on unmount.

| Prop               | Type                              | Notes                                                                                                                                                                          |
| ------------------ | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `value`            | `string \| undefined`             | Controlled source. External changes are pushed with `replaceAll`.                                                                                                              |
| `defaultValue`     | `string`                          | Seed for uncontrolled use.                                                                                                                                                     |
| `readonly`         | `boolean`                         | Calls `Crepe#setReadonly`.                                                                                                                                                     |
| `placeholder`      | `string`                          | Crepe `Placeholder` feature text.                                                                                                                                              |
| `onchange`         | `(markdown: string) => void`      | Fired on every `markdownUpdated` event.                                                                                                                                        |
| `onupload`         | `(file: File) => Promise<string>` | Dropped/pasted/uploaded file → the URL the editor inserts. Defaults to the standalone artifact upload (`uploadArtifactAsUrn`).                                                 |
| `onReferenceClick` | `ReferenceClickHandler`           | Chip click handler for readonly surfaces (the QuickView drawer). Edit mode never calls it — a chip click there selects the node. Without a handler readonly chips stay static. |
| `domain`           | `string`                          | Current domain segment, `''` on global pages — scopes the `@` picker's domain mode and recents slice.                                                                          |
| `sources`          | `PickerSources`                   | Injectable picker/chip data bundle (stories pass mocks; default = the real services). Must carry `resolveLabel` when given.                                                    |

Rules baked into the wrapper:

- The external value sync pushes only when the incoming `value` differs from the markdown the editor last reported outward — never from the live document (see Mentions and references → Editor-value sync). Both sides are compared normalized (`normalizeMarkdown` in `markdown-normalize.ts`), which collapses Milkdown's empty-paragraph `<br />` convention and its per-block trailing newlines.
- Stored markdown must never contain HTML (API consumers, search indexing, and plain-text renderers read the raw source). Milkdown serializes an empty paragraph — a blank line made with Enter in the WYSIWYG, or a pasted empty `<p>` — as a `<br />` line (upstream's "preserve empty line" convention; plain markdown cannot express an empty paragraph). The wrapper normalizes every `markdownUpdated` payload: br-only lines collapse to a plain paragraph break, outside code fences. Trade-off: a blank line collapses to a paragraph break after save/reopen — the standard markdown meaning.
- A `pushing` flag suppresses the `markdownUpdated` echo while `replaceAll` writes an external value into the editor.
- The theme CSS variables live on Milkdown's **own wrapper**: the core injects a `div.milkdown` inside the anchor element (`createViewContainer` in `@milkdown/core`), and the themes define `--crepe-color-*` / `--crepe-font-*` there. Custom properties inherit from the nearest definition, so the token mapping must target that wrapper (`.milkdown-host .milkdown-root .milkdown`), not our anchor — a mapping on the anchor is silently beaten by the theme. With the mapping in place, light and dark both resolve from the design tokens (Storybook's `.dark` class / the app's `[data-theme='dark']` only need to flip the tokens; the wrapper override adds shadow variables).
- Crepe paints **every floating-menu icon** (block handle, selection toolbar, slash menu, table cell/row handles, link tooltips), the virtual caret, and the image resize handle from `--crepe-color-outline`. The mapping resolves it to `--text-3` — never to a border colour: the theme also builds hairlines from it (table borders, `hr`, dividers, at 20% alpha — visually stable either way), but icons and the caret need readable contrast against the surface. `--crepe-color-hover` maps to `--sunken` — popup backgrounds sit on `--crepe-color-surface` (`--surface-2`); mapping hover to the same token removed all hover feedback.
- Editor chrome follows the app conventions: the caret is Crepe's virtual cursor (the stylesheet sets `caret-color: transparent` on the native caret), pinned to `--text-2` on `.ProseMirror-focused`; `.crepe-placeholder::before` uses `--text-3` like every input placeholder and `.cm-placeholder`; editor links paint with `--accent-ink` (gold fill ≠ gold text — `--crepe-color-primary` stays the fill accent for outlines and drag handles). Storybook stories "Write — placeholder and caret ink" and "Write — link ink" assert these computed colours.
- Crepe's reset gives the ProseMirror content a page-like `60px 120px` padding. The wrapper overrides it to a field-like `12px 14px`, matching the source editor's `.cm-content`.
- The frame theme's prose defaults (serif headings at ~2–2.6em, weight 400) do not fit the app. The wrapper restyles headings to the app's prose scale — display sans, weight 600, 24/20/16/14/13.5/12px steps — and sets paragraph line-height to 1.6. Because every surface renders through this editor, these rules are the single typography definition.
- Crepe's floating menus (selection toolbar, block handle, slash menu, link tooltip) mount **inside the editor DOM** — the plugins append them to the ProseMirror view's parent, not to `document.body`. Rules that follow: no ancestor of the editor may set `overflow: hidden` (round the inner surfaces instead), and the popups carry `z-index: 500` from the wrapper so they overlay page content (app dropdowns sit at 1100, overlays at ~100). In `Markdown.svelte` the body only scrolls in preview/markdown modes of the boxed surface; in write mode it flows visibly so the menus are never clipped, and a readonly preview never scrolls at all (its `overflow` passes through to the surrounding rail/page — the comment sidecar relies on this).
- File handling splits on content: pure-image drops/pastes pass through to Crepe's uploader (which maps drop coordinates), while any event containing a non-image file is taken over by a capture-phase handler that uploads via `onupload` and inserts a capsule link at the selection (via `insertText` + `addMark` — `replaceSelectionWith` would let the text inherit the cursor's stored marks, silently dropping the link mark).
- The editor DOM never shows a URN as an href — Milkdown's link mark sanitizes unknown URI schemes to `href=""` (`SAFE_PROTOCOLS` in preset-commonmark, not configurable). Artifact links are instead tagged by an inline decoration (`setProps({ decorations })` after `create()`) carrying `data-artifact-id`, and styled as capsules on `.md-artifact-capsule-link`. On readonly surfaces a click delegate on the host opens `artifactDownloadUrl(id)` in a new tab. Reference chips are `ref_chip` nodes — their `href` attribute passes through unsanitized (the sanitizer touches link marks only) — and render through their node view (see Mentions and references).

## `markdown-source.ts`

`markdown-source.ts` exports `MD_LANG`, `sourceEditorTheme`, and `sourceEditorExtensions` — the CodeMirror markdown language, the token-matched editor theme, and the highlighting extension list. Both are consumed only through `Markdown.svelte` (markdown mode).

## Longtext DVT node

`input-longtext` composes `Markdown.svelte` with `mode="write"`: the user gets the same toolbar (Preview / Write / Markdown), the same upload plumbing, and the fullscreen expand overlay as the standalone component. The node adds only the form glue: the label, the `values` bag writeback, field errors, and the field box (the embedded primitive runs `bare`; the wrapper draws the border and focus ring through `.dvt-input-longtext-field`).

The readonly branch (no `values` bag) renders `<Markdown readonly bare>` — the same Milkdown preview as everywhere else, inside the field box. View, quickView, and card templates bind a `longtext` field through the auto `input` node for exactly this branch: `resolveAutoInput` dispatches longtext here, so a display surface shows the rendered document. A plain `field` row renders the raw source as text — use the auto `input` (labeled, boxed) or the `markdown` node (label-less) for a longtext.

Image files dropped or pasted into the WYSIWYG editor go through the `uploadFile` prop: the component uploads to `POST /Api/core/artifacts` and references the stored artifact as `urn:facet:artifact:<id>`, so `Document::ArtifactRefs` can extract the reference on save. Non-image files insert as `[filename](urn:facet:artifact:<id>)` capsule links. A synthetic uploader prop (`uploadFile`) keeps stories free of a live backend.

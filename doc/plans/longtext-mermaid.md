# Plan — Mermaid diagrams in longtext markdown

Status: **implemented.** Mermaid fences render as diagrams in every
`Markdown.svelte` surface. The skill corpus (`src/agent_tools/skills/longtext.md`)
and this plan both describe the built behaviour. Related docs:
[`frontend/markdown-editor.md`](../frontend/markdown-editor.md) → Diagrams (the
concern doc), [`frontend/chat.md`](../frontend/chat.md) (the renderer this plan
generalizes), [`backend/workspace-assistant.md`](../backend/workspace-assistant.md)
(the skill corpus).

---

## 1. Purpose

A `longtext` field holds markdown. Mermaid fenced blocks already render as
diagrams in the chat assistant's message renderer —
`markdown-renderer.ts` splits ` ```mermaid ` tokens into segments and
`MermaidDiagram.svelte` renders them. The longtext editor has no mermaid
path: a ` ```mermaid ` fence renders as a plain highlighted code block.

This plan brings mermaid rendering to the longtext render path, so an agent
or a user can write a diagram inside a document and every reader sees the
rendered graph. **No backend change** — the stored markdown stays a plain
fenced code block, the same content the chat renderer consumes.

## 2. Findings

| Fact | Where |
| --- | --- |
| One component owns every markdown render surface: `Markdown.svelte` (preview / write / source) wrapping `Milkdown.svelte` (`@milkdown/crepe`, ProseMirror). It is composed by `DvtInputLongtext` (longtext fields), `DvtMarkdown` (markdown views), `CommentSurface` (comment composer + display), and `DomainOverviewTab` — one node view lands on all of them at once | imports of `primitives/content/Markdown.svelte` |
| The custom-node precedent: plugins are `.use()`d between Crepe construction and `create()`; `createRefChipPlugins` registers the `ref_chip` node views and claims mdast nodes in `parseMarkdown`. Node views carry the DOM contract; `setProps` after `create()` adds decorations and input handlers | `frontend/src/lib/components/primitives/content/ref-chip.ts`, `Milkdown.svelte` L880-912 |
| Crepe's CodeBlock feature renders fenced blocks with a language picker; the ProseMirror `code_block` node carries the language attribute. A node-view factory can return the default view for every language except `mermaid` | `@milkdown/crepe` CodeBlock feature |
| The chat renderer already owns a mermaid component: lazy-loads `mermaid` `^11.9.1` exactly once (`loadMermaid`), initialises with `startOnLoad: false`, `securityLevel: 'strict'`, `theme: 'base'`, unique ids for mermaid's cache, skips render while `streaming`, renders an error card on parse failure, guards redundant re-renders on `lastRenderedSrc` | `frontend/src/lib/components/features/chat/MermaidDiagram.svelte` |
| Chat detects mermaid fences at `tok.lang === 'mermaid'` and pushes a `{ kind: 'mermaid', source }` segment | `frontend/src/lib/components/features/chat/markdown-renderer.ts` L352-371 |
| Layering: primitives never import features; features import primitives. `MermaidDiagram.svelte` lives in `features/chat/`, so the editor cannot import it as-is — the component must move to `primitives/content/` | `doc/frontend/workflow.md` → Design system |
| The editor-value sync rule: the wrapper pushes an externally changed `value` only when it differs from the last reported markdown (normalized). Mermaid fences must survive parse → serialize byte-stable, or every mount would look like drift (the chip node's `toMarkdown` is the byte-compat precedent) | `markdown-editor.md` → Editor-value sync; `ref-chip.ts` |
| The source mode (`markdown` toggle) is CodeMirror (`markdown-source.ts`) and shows raw text with its own highlighting — diagrams never render there, which matches its purpose | `frontend/src/lib/components/primitives/content/markdown-source.ts` |
| `Document::Links` scans longtext text for `[label](url)` and bare `urn:facet:` tokens **including inside fences** — the accepted quote-a-URN trade-off. Mermaid sources rarely carry `urn:facet:` tokens; no change | `doc/backend/links.md` → Longtext parser limits |
| Stories double as component tests (play functions); pure logic lives in the Vitest `server` project. The node view is DOM-bound → story plays are the venue | `doc/frontend/workflow.md` → Testing strategy |
| Bundle: `mermaid` is large (~1 MB) and lazy-loaded in chat today. A document without mermaid fences must never pull the chunk | `MermaidDiagram.svelte` header comment; `frontend/package.json` |

## 3. Verdict

Build it as a ProseMirror node view for `code_block` nodes with language
`mermaid`, registered in `Milkdown.svelte` next to `createRefChipPlugins`,
sharing one `MermaidDiagram` component with chat. The component moves from
`features/chat/` to `primitives/content/` (layering direction). No backend
work, no schema change, no stored-form change.

## 4. Design

### 4.1 Stored form — unchanged

The stored markdown keeps the plain fence:

    ```mermaid
    graph TD
      A[Start] --> B[End]
    ```

`parseMarkdown` needs no claim logic (the fence already parses as a
`code_block` with `language: "mermaid"`), and `toMarkdown` must emit the
fence back byte-stable — same invariant as the chip's round-trip. A spec
pins it: a document containing a mermaid fence reports back the identical
markdown through `markdownUpdated`.

### 4.2 The shared component moves down

`MermaidDiagram.svelte` moves `features/chat/` → `primitives/content/`.
Chat imports it back (`features/chat/Markdown.svelte`). Props stay
`{ source, streaming? }`; the lazy `loadMermaid` singleton and
`securityLevel: 'strict'` init stay exactly as they are — one mermaid
instance per app, one security posture.

### 4.3 The node view

New file `frontend/src/lib/components/primitives/content/mermaid-fence.ts`
(sibling of `ref-chip.ts`): `createMermaidPlugins({ isReadonly })` — a
Milkdown plugin registered in `Milkdown.svelte` beside
`createRefChipPlugins`.

- **Node view factory for `code_block`.** When `node.attrs.language !==
  'mermaid'`, return `null` — Crepe's default code-block view (language
  picker, highlighting) stays. When it is `mermaid`:
  - **Readonly** (preview surfaces): render the diagram only — mount
    `MermaidDiagram` with the node's text content.
  - **Edit mode** (write): the node view keeps ProseMirror's `contentDOM`
    as the source area (the fence stays editable where the caret is), and
    renders the diagram in a preview area below the source. This is the
    GitHub-style split — deterministic, no selection heuristics.
  - **Re-render:** `update(node)` diffs the text content and re-renders the
    preview debounced (~400 ms after the last change) — mermaid renders are
    too costly per keystroke. `ignoreMutation` covers the preview area;
    mutations inside `contentDOM` stay ProseMirror's.
- **Lazy mount.** The node view only exists for mermaid fences, and
  `MermaidDiagram` keeps its own `import('mermaid')` — a document without
  fences never constructs the view, and the chunk loads only when the first
  diagram renders.
- **Errors.** A parse failure renders the component's error card inside the
  node — the source stays editable above it.
- **Theme.** `theme: 'base'` matches the chat renderer; CSS variables can
  restyle through mermaid's `themeVariables` later if the two surfaces must
  diverge.

### 4.4 Where it lands

Every `Markdown.svelte` consumer gets it with no per-surface work:
`DvtInputLongtext` (longtext fields in the document view), `DvtMarkdown`
(markdown views), `CommentSurface` (comments — the chat-like surface),
`DomainOverviewTab`. The CodeMirror source mode keeps showing raw text.

### 4.5 What does not change

Stored markdown, the backend (`links`, `artifact_references`, validation),
reference chips, artifact capsules, paste-to-chip, the picker, and the chat
renderer's behaviour (it keeps its own segment pipeline; it only re-points
its import).

## 5. Work breakdown

| Step | Work | Files |
| --- | --- | --- |
| 1 | Move `MermaidDiagram.svelte` to `primitives/content/`; re-point the chat import; no behaviour change | `features/chat/MermaidDiagram.svelte` → `primitives/content/MermaidDiagram.svelte`, `features/chat/Markdown.svelte` |
| 2 | Add `mermaid-fence.ts`: node-view plugin with the readonly/edit split, debounced re-render, `null` factory for non-mermaid fences | `primitives/content/mermaid-fence.ts` |
| 3 | Register the plugin in the editor beside `createRefChipPlugins` | `primitives/content/Milkdown.svelte` |
| 4 | Stories + play functions: diagram renders (assert an `svg` appears in the node view), invalid source shows the error card, byte-stable round-trip through `markdownUpdated`, readonly shows diagram only | `Markdown.stories.svelte` (or `DvtInputLongtext.stories.svelte`) |
| 5 | Docs: `markdown-editor.md` gains a "Diagrams" section (stored form, node view, render split); `chat.md` re-points the component path; this plan records deviations and retires | `doc/frontend/markdown-editor.md`, `doc/frontend/chat.md` |

## 6. Testing strategy

Story play functions (the DOM-bound venue): render-to-svg, parse-failure
error card, byte-stable serialization, readonly vs edit split. No Vitest
project coverage — the only pure logic is the language check (one
expression). No backend specs — no backend change.

## 7. Out of scope

Diagram theming UI, exporting rendered SVGs, mermaid config directives
beyond the shared `initialize` call, CodeMirror source-mode previews, and
any new markdown feature beyond the fence.

## 9. Implementation notes

What shipped, and where it deviates from the design above:

- **The node view registers on the commonmark schema's own context.** `$view` resolves the node type through the schema slice at create time. The editor is created by `@milkdown/crepe`, which is a separate module instance from the app's `@milkdown/kit` imports — so `createMermaidPlugins` returns `[...codeBlockSchema, $view(codeBlockSchema.node, …)]`. Without the slice, `Editor.create` throws `Context "schema" not found`.
- **The factory replaces Crepe's `code_block` view by registration order.** Both factories ride the `nodeViews.code_block` slot; the last registration wins. Crepe applies its CodeMirror feature in the constructor, and `Milkdown.svelte` `.use()`s the mermaid plugin after — so the mermaid factory claims the slot and returns `null` for non-mermaid fences. ProseMirror accepts a `null` view and renders the default DOM.
- **Readonly view is a leaf; edit view keeps its `contentDOM`.** This also gives `setNodeMarkup` a path to the view (ProseMirror only reaches `update` for a block with no `contentDOM`), which is how a language change re-creates the view.
- **One mounted component, new source via `$set`.** `mount` flushes its root effect synchronously, so the component exists at node-view construction; re-renders pass a new `source` prop after the debounce and the component's own effect does the guarded render.
- **Stories.** `Markdown.stories.svelte` covers render-to-svg, the parse-failure error card, the edit-mode source+diagram split with a byte-stable fence around an in-fence edit, and a non-mermaid fence keeping the default `<pre data-language>` rendering.

## 10. Recorded decisions

- **The skill ships before the renderer.** `longtext.md` documents mermaid
  as supported from its first release; this plan is the bridge. Until the
  build lands, an agent-written fence renders as a plain code block —
  lossless (the source survives), harmless, and fixed by this plan. The
  alternative (documenting the limitation) was rejected: the corpus would
  need a second edit, and the temporary gap has no data cost.
- **Node view over decoration.** Decorations cannot own the editing
  contentDOM; the ref_chip precedent (an atom node) does not transfer to
  editable block content. The code_block node view with a separate preview
  area keeps one source of truth for the text.
- **Edit-mode split over selection heuristics.** Showing source + diagram
  together in write mode avoids cursor-tracking complexity (the
  Obsidian-style "source while the caret is inside" behaviour stays a
  possible follow-up).

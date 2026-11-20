# Templating

Jinja2 template rendering for derived document surfaces. One concern serves both the `display_name` label and the `search` corpus: each is a doctype-level Jinja2 template rendered in Crystal at mutation time.

## Source files

- `src/templating.cr` — module root and the `Templating::Error` / `Templating::ReferenceResolver` definitions
- `src/templating/engine.cr` — `Templating::Engine`: compile cache, render, AST root collection
- `src/templating/context.cr` — `Templating::Context`: variable bindings for a document mutation

## Public API

| Entry point | Purpose |
|---|---|
| `Templating::Engine.compile(source)` | Compiles (and caches) a template. Raises `Templating::Error` on invalid syntax. |
| `Templating::Engine.render(source, bindings)` | Renders a template. Raises `Templating::Error` on a runtime failure. |
| `Templating::Engine.roots(source)` | Collects the root variable names of a template — used by `Doctype::Validation` for authoring-time checks. |
| `Templating::Context.build(definition, content, resolver?, display_name?)` | Builds the `Crinja::Variables` bindings for a document mutation. |
| `Templating::ReferenceResolver` | Abstract protocol for reference resolution (see `Document::DisplayName::DatabaseReferenceResolver`). |

Consumers:

- `Document::DisplayName.compute` — renders `definition.display_name` into the projection label (truncated to 255 chars).
- `Document::Search.compute` — renders `definition.search` into the trigram-search corpus (whitespace-normalised, truncated to 256 chars). A doctype with no template renders nothing; its corpus is the folded display_name (see [`search.md`](search.md) → The searchability flag).
- `Doctype::Validation.validate_display_name` / `validate_search` — compile the template and check every root variable against the doctype fields and the reserved variables (`content`; `display_name` in `search` templates only).

## Binding rules

Context variables come from the doctype definition and the post-mutation content:

- Every declared field name is bound as a top-level variable: `{{ first_name }}`, `{{ address.postal_code }}`.
- The raw content tree is exposed as `{{ content.address.postal_code }}` for advanced templates.
- The reserved `display_name` variable carries the document's display label when the caller supplies one (`Document::Search` passes it for `search` templates). Without a value it renders empty, like an absent optional field. It binds after the field loop, so it wins over a field of the same name — the same precedence `content` has. A `display_name` template cannot reference it: the validator rejects the self-reference.
- The document `id` is not bindable. `validate_template` requires every
  template root variable to be a declared field or a reserved variable
  (`content`, plus `display_name` in `search` templates), and `id` is
  neither — a template root of `{{ id }}` is rejected at authoring time
  (`'id' is not defined in the doctype fields`, e.g. in `display_name`).
  There is no `id` binding at runtime either: `Templating::Context.build`
  binds the declared fields and the reserved variables only
  (`src/templating/context.cr`). A doctype whose documents carry a
  human-facing identifier declares a dedicated unique string field for it
  and templates that field.
- Reference fields resolve to the referenced document's stored `display_name` via the injected resolver; unresolved references fall back to the target doctype's bare name (never the raw id). Collection references resolve to the first element.
- Money fields (declared `money`, or money-shaped objects nested in content) render as `"<currency> <value>"` (e.g. `USD 120000`).
- Missing fields render empty and never fail the render — an absent optional field is a normal data state.
- Autoescape is off; templates produce plain text. Compiled templates are cached per source string.

## Quirks

- **Missing fields are safe; real errors are fatal.** A nested path over an absent optional field renders empty. But an invalid filter, a type error, or bad syntax raises `Templating::Error` — the mutation is rejected and its transaction rolls back.
- **Empty strings are truthy.** Crinja deviates from Jinja2's Python truthiness: `{{ nick }}` set to `""` passes `{% if nick %}`. Compare explicitly (`{{ nick == '' }}`) when the empty value must follow the false branch.
- **Tag-argument variables are not validated.** `Templating::Engine.roots` walks the AST of `{{ ... }}` expressions only; variables used inside `{% if %}` / `{% for %}` arguments are stored as raw tokens by the Crinja parser and skip authoring-time validation.
- **Arrays render Python-style.** `{{ tags }}` prints `['a', 'b']` — use `{{ tags | join(', ') }}` for a readable list.
- **Autoescape must be disabled by constant, not by flag.** Crinja 0.9.0 ships an inverted `config.autoescape = Bool` setter: `false` turns autoescape ON, and every string printed from a template then goes through `HTML.escape` (`'` → `&#39;`). The engine assigns `Crinja::Config::Autoescape::DISABLED` directly; do not replace it with the Bool setter.
- **Global function names shadow fields.** A field named `range` (or `dict`, `namespace`, …) is unreachable as a bare variable because Crinja resolves globals first.

## Example

```yaml
# doctype definition (abridged)
display_name: "{{ first_name }} {{ last_name }}"
search: "{{ first_name }} {{ last_name }} {{ email }}"
```

```
content: {"first_name": "Ada", "last_name": "Lovelace"}
→ display_name: "Ada Lovelace"
→ search:       "Ada Lovelace ada@facet.local"
```

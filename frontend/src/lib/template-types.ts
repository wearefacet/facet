// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Template node types for document view templates.
 *
 * A document view template is a recursive tree of typed nodes stored in the
 * `template` field of a `core.DocumentView` document. Each node has a `type`
 * discriminator and additional properties that vary by type.
 *
 * The frontend maps each type to a Svelte component via a registry in
 * `DocumentViewTemplate.svelte`. This same union can be used by the backend
 * for server-side validation of template structure.
 *
 * Runtime resolution helpers for these templates live in `./template-resolve`.
 */

/** A single tab inside a `tabs` container. Not a top-level template node. */
export interface TabDescriptor {
	type: 'tab';
	label: string;
	children: TemplateNode[];
}

/** Tab container — renders tab navigation and panels. */
export interface TabsNode {
	type: 'tabs';
	tabs: TabDescriptor[];
}

/** Label node — renders a document field value with interpolation support. */
export interface LabelNode {
	type: 'label';
	value: string;
}

/** Field node — renders a labeled row: label on the left, resolved value or children on the right. */
export interface FieldNode {
	type: 'field';
	/** Optional label. When omitted, the field renders a single-column
	 * value-only row (no label lane) — useful when the surrounding
	 * `section` already provides the label. */
	label?: string;
	value: string;
	/** Optional children rendered inside the value area instead of the resolved text. */
	children?: TemplateNode[];
}

/** Markdown node — renders a `longtext` field as readonly markdown prose
 * through the shared `Content/Markdown` primitive. Read-only: editing goes
 * through an `input-longtext` node on the form. Renders nothing when the
 * field is empty. */
export interface MarkdownNode {
	type: 'markdown';
	/** The document field key carrying the markdown source. Dotted paths
	 * resolve (the node is read-only), unlike `input-*` bindings. */
	field: string;
}

/** Object wrapper — sets a nested field as the root data for children. */
export interface ObjectNode {
	type: 'object';
	field: string;
	children: TemplateNode[];
}

/** Conditional — renders children when field is truthy (or equals `value`), else otherwise. */
export interface IfNode {
	type: 'if';
	field: string;
	/** Optional — when set, uses strict equality instead of truthiness. */
	value?: unknown;
	children: TemplateNode[];
	else?: TemplateNode[];
}

/** Array iterator — iterates over `$field` array, renders children with each item as root. */
export interface ArrayNode {
	type: 'array';
	field: string;
	children: TemplateNode[];
	/** Read-only display layout. `inline` (default) flows primitive items in a
	 * wrapping row — the pill-list pattern with `capsule` children. `stack`
	 * renders one bordered block per item. Object items always render as
	 * cards in both layouts. */
	layout?: 'inline' | 'stack';
}

/** Dict iterator — iterates over `$field` object entries, renders children with `{ key, value }` as root. */
export interface DictNode {
	type: 'dict';
	field: string;
	children: TemplateNode[];
}

/**
 * Source descriptor for a `relation` node. The two supported query modes
 * mirror the two list primitives the backend already exposes:
 *  - `children`: the relation doctype is owned by the current document
 *    (walked via `parent_id`). Routed through `.doc(currentId).children(rel)`.
 *  - `filter`: the relation doctype carries a reference back to the current
 *    document (walked via a `field__eq` filter on the bare/qualified id).
 *
 * No new backend filter is introduced — these are the only two query modes
 * both the frontend DataSource and `Document::List` support natively.
 */
export type RelationSource = { kind: 'children'; rel: string } | { kind: 'filter'; field: string };

/**
 * Render target for each row of a relation node.
 *
 * - `'capsule'` (default): renders the relation row as a hydrated reference
 *   capsule driven by `referenceField`. Each row's reference value is
 *   resolved through `Capsule.svelte`, giving the same hydration + tinting
 *   behavior as a `$field` reference on a DvtField. Clicking the capsule
 *   is wired to `onreferenceclick`.
 * - `'inline'`: renders the row using the relation doctype's `inline` view
 *   template (falling back to `quickView` when `inline` is absent, mirroring
 *   `loadDoctypeView`'s view→quickView fallback). Each row is rendered by a
 *   recursive `DocumentViewTemplate` instance, scoped to that row's data.
 *
 * When the relation node is `editable: true` (form mode only), each inline
 * row instead renders the relation doctype's `form` template so its fields
 * can be edited in place. `view: 'capsule'` is incompatible with
 * `editable: true` — capsule mode is read-only.
 */
export type RelationView = 'capsule' | 'inline' | 'table';

/** A single column for a `view: 'table'` relation node. */
export interface RelationTableColumn {
	/** Column key. Either a plain field on the row (`role`, `start_date`) or
	 * a dotted path that crosses one or more `reference` fields
	 * (`contact.email`, `contact.full_name`, `owner.department`). Each
	 * non-leaf segment must name a `reference`-typed field on the doctype
	 * reached so far; the renderer resolves the target document(s) on
	 * demand. Crossing a reference is auto-detected from the key — no
	 * extra flag is required. */
	key: string;
	/** Column header label. */
	label: string;
	/** Optional fixed column width (CSS length, e.g. "150px"). */
	width?: string;
	/**
	 * Inline-editable cell. Present (as `true`) only on boolean columns the
	 * template author marked updatable. When the viewer holds `update` on
	 * the relation doctype and the surface is read-only (no form `values`
	 * bag), the cell renders as a toggle that PATCHes the row document
	 * directly. Single-segment keys only — dotted keys resolve their leaf
	 * on a referenced document, so the flag is ignored there and the cell
	 * stays read-only.
	 */
	editable?: true;
}

/**
 * Relation node — fetches a list of related documents and renders each row.
 * Used for inline "show contacts of this company" / "show companies of this
 * contact" panels inside a DocumentView template.
 */
export interface RelationNode {
	type: 'relation';
	/** Section title shown above the rendered rows. */
	label: string;
	/** Qualified doctype whose documents we list (e.g. "crm.CompanyMembership"). */
	doctype: string;
	/**
	 * Reference field on the relation doctype whose value is rendered as the
	 * capsule label. Required for `view: 'capsule'`. Must be a top-level
	 * `reference`-typed field on the relation doctype (e.g. "contact").
	 */
	referenceField?: string;
	/** How to bind the list query to the current document. */
	source: RelationSource;
	/** Render mode. Defaults to `'capsule'`. */
	view?: RelationView;
	/** Columns for `view: 'table'`. Required when `view === 'table'`; ignored
	 *  in other modes. Dotted keys crossing `reference` fields are hydrated
	 *  automatically by the renderer. */
	columns?: RelationTableColumn[];
	/** Max items to fetch (default 25). */
	limit?: number;
	/**
	 * Whether the relation is editable inside a form template. When `true`
	 * and the parent `DocumentViewTemplate` is rendering in form mode
	 * (a `values` bag was supplied), each row renders the relation doctype's
	 * `form` template and the section exposes Add / Remove affordances. The
	 * parent `DocumentForm` collects the staged drafts and issues the
	 * per-child create / update / delete calls against
	 * `doc(parentId).children(rel)` after the parent saves.
	 *
	 * Implies `view: 'inline'` — capsule rows are read-only. Only `children`
	 * sources are supported: `filter`-bound relations are read-only by
	 * construction (the parent does not own those rows).
	 */
	editable?: boolean;
}

/** Grid layout — renders children in CSS grid columns with the given proportions. */
export interface GridNode {
	type: 'grid';
	/** Space-separated positive integer fractions, e.g. "1 2" for 1/3 + 2/3,
	 * "1 1 1" for three equal columns, "3 1" for a 3:1 main/sidebar split.
	 * Lengths (px, %, etc.) are not supported — the layout is fraction-only,
	 * and non-conforming tokens fall back to `1fr` so the grid never collapses. */
	layout: string;
	/** Exactly one child per column. Each child is typically a `col`/`sidebar`
	 * wrapper. A 2-column grid renders a shared vertical divider between its
	 * cells. For inline rows of labels/capsules, use a `row` node instead. */
	children: TemplateNode[];
}

export interface RowNode {
	type: 'row';
	/** Raw CSS `grid-template-columns` value, e.g. "auto 1fr auto". Used for
	 * one-line summaries where each column sizes to its content (`auto`) or
	 * takes the remaining space (`1fr`). For column-based layouts (main +
	 * sidebar), use a `grid` node with integer fractions. */
	layout: string;
	/** Inline children, one per grid column — typically `label` and `capsule`. */
	children: TemplateNode[];
}

/** Column wrapper — a single grid column that stacks its children vertically. */
export interface ColNode {
	type: 'col';
	children: TemplateNode[];
}

/** Image node — renders an `<img>` with the interpolated `src`. */
export interface ImageNode {
	type: 'image';
	src: string;
	alt?: string;
	/** Optional CSS class for sizing, e.g. "avatar" */
	variant?: string;
}

/**
 * Image-artifact node — renders a stored `file`-typed field as an `<img>`
 * miniature. Unlike the `image` node (which interpolates a URL string), the
 * value here is a bare artifact id resolved to a grant URL via
 * `GET /Api/core/artifacts/:id` on mount. Used for doctype logos / avatars
 * stored as `file` artifacts.
 */
export interface ImageArtifactNode {
	type: 'image-artifact';
	/** Field key on the document carrying the artifact id (without `$`). */
	field: string;
	/** Alt text (supports `$field` interpolation). */
	alt?: string;
	/** Render shape. `avatar` = circular; `thumbnail` = square. Defaults to
	 *  `thumbnail` (inline miniature in a section row). */
	variant?: 'avatar' | 'thumbnail';
	/** Optional explicit pixel size. */
	size?: number;
}

/** Link node — renders an `<a>` with interpolated `href` and `label`. */
export interface LinkNode {
	type: 'link';
	href: string;
	label: string;
}

/** Title node — renders a heading (h1–h6) with interpolated text. */
export interface TitleNode {
	type: 'title';
	/** The text content (supports `$field` interpolation). */
	value: string;
	/** Heading level. Defaults to 2 if not set. */
	level?: number;
}

/** Capsule node — renders a small badge/pill with interpolated text. */
export interface CapsuleNode {
	type: 'capsule';
	/** The text content (supports `$field` interpolation). */
	value: string;
}

/** Horizontal rule node — renders an `<hr>` separator. */
export interface HrNode {
	type: 'hr';
}

/**
 * Document show-page header node. Renders the document title, an optional
 * status chip (the only color-bearing chip — it is a state machine), optional
 * neutral categorical chips, and an optional subtitle line.
 *
 * The fields referenced here are the canonical "promoted" fields: the renderer
 * does not deduplicate them from the body sections. By convention, authors
 * exclude these fields from `section` blocks so the header and the body do
 * not repeat the same value. This is the explicit version of the
 * "header-promoted fields are removed from the grid" rule.
 */
export interface HeaderNode {
	type: 'header';
	/**
	 * Title text, usually `"$name"` or `"$title"`. Supports `$field`
	 * interpolation. When omitted, no title heading is rendered — the show
	 * route's doctype chrome already renders the page h1, so a doctype that
	 * does not want a second title in the body leaves this unset.
	 */
	title?: string;
	/**
	 * Field key whose declared `enum` value becomes the status chip. When the
	 * field's `values[].color` is declared, that color is used; otherwise the
	 * chip falls back to the neutral variant. Only this chip receives color —
	 * `chips` always render neutral.
	 */
	statusField?: string;
	/** Field keys rendered as neutral categorical chips (e.g. industry, size). */
	chips?: string[];
	/** Optional subtitle line, supports `$field` interpolation. */
	subtitle?: string;
	/**
	 * Optional logo field key (`file`-typed). When set, the header renders a
	 * circular avatar to the left of the title by resolving the stored
	 * artifact id to a grant URL on mount. By convention the same field is
	 * not repeated in a body `section` — header-promoted fields are excluded
	 * from the body.
	 */
	logo?: string;
}

/**
 * Section node — a named group of fields rendered with an uppercase eyebrow
 * label and a two-column label/value grid. Replaces the ad-hoc
 * `title` + stacked `field` pattern for grouped data.
 */
export interface SectionNode {
	type: 'section';
	/** Eyebrow label (plaintext, no `$field` interpolation). */
	label: string;
	/** Children — typically `field` rows, but any atoms are allowed. */
	children: TemplateNode[];
}

/**
 * Sidebar node — the right rail of a record view. Holds metadata that is not
 * a business field of the document: owner, tags, provenance. Composed of
 * `section` children (or any atoms). Rendered as a narrow `aside` lane, so it
 * must be placed as the last child of a `grid` whose layout gives it a fixed
 * fraction (e.g. `"1 220px"`).
 */
export interface SidebarNode {
	type: 'sidebar';
	/** Children — typically `section` blocks, but any atoms are allowed. */
	children: TemplateNode[];
}

/**
 * Record-meta node — provenance block read from `document.meta`. Renders
 * "Created <date>", "Updated <relative>", and an optional History link to the
 * document's audit trail. The one component that reads `meta` timestamps, so
 * every doctype inherits it without each fixture hand-copying it.
 */
export interface RecordMetaNode {
	type: 'record-meta';
	/** Show the History link to the audit trail. Defaults to `true`. */
	history?: boolean;
}

/** Auto input node — renders the correct control from the field's declared type.
 *
 *  One node covers every editable scalar field: the doctype definition
 *  already knows the control (enum options, reference target, required
 *  flag, url/phone/integer sub-typing), so the template carries only the
 *  binding and optional chrome overrides. Specialized `input-*` nodes stay
 *  as deliberate overrides — they force a control the definition cannot
 *  express (an email keyboard, a url prefix). Container and computed fields
 *  (`array`, `object`, `dictionary`, `data`) never bind: the validator
 *  rejects them at authoring time and the component renders a diagnostic.
 *  See `src/lib/doctype/autoInput.ts` for the dispatch table. */
export interface InputAutoNode {
	type: 'input';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the control. Defaults to the field's `title`, then the humanized key. */
	label?: string;
	/** Placeholder text shown when empty. */
	placeholder?: string;
	/** Helper text displayed below the control. */
	helper?: string;
	/** Whether the field is required. Defaults to the field definition's `required`. */
	required?: boolean;
}

/** Text input node — renders an editable text field with configurable type. */
export interface InputTextNode {
	type: 'input-text';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the input. */
	label: string;
	/** HTML input type. Defaults to "text". */
	inputType?: 'text' | 'email' | 'number' | 'password' | 'date' | 'tel' | 'url';
	/** Placeholder text shown when empty. */
	placeholder?: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the input. */
	helper?: string;
	/** Static adornment rendered inside the input on the left side (e.g. "https://"). */
	prefix?: string;
}

/** Datetime input node — edits a `datetime`-typed field via the timezone-aware DatetimePicker.
 *
 *  The bound value is a UTC RFC-3339 string (`...Z`); the user enters
 *  wall-clock time in their own timezone (the `core.timezone` setting).
 *  See `doc/frontend/datetime-picker.md`. */
export interface InputDatetimeNode {
	type: 'input-datetime';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the picker. */
	label: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the picker. */
	helper?: string;
}

/** Period input node — edits a `period`-typed field via the PeriodPicker.
 *
 *  The bound value is the complete `{start, end}` pair of UTC RFC-3339
 *  timestamps (or `''` when cleared); each bound is entered as wall-clock
 *  time in the user's timezone. Bounds are `[)` — start strictly before end.
 *  See `doc/frontend/period-picker.md`. */
export interface InputPeriodNode {
	type: 'input-period';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the pair. */
	label: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the pair. */
	helper?: string;
}

/** Date-period input node — edits a `dateperiod`-typed field via the PeriodPicker.
 *
 *  The bound value is the complete `{start, end}` pair of `YYYY-MM-DD`
 *  calendar dates (or `''` when cleared). Bounds are `[]` — inclusive both
 *  ends, start may equal end. See `doc/frontend/period-picker.md`. */
export interface InputDateperiodNode {
	type: 'input-dateperiod';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the pair. */
	label: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the pair. */
	helper?: string;
}

/** Date input node — edits a `date`-typed field via the date-granularity
 *  DatetimePicker.
 *
 *  The bound value is a `YYYY-MM-DD` calendar date string (or `''` when
 *  cleared). A calendar date is not an instant — the value renders verbatim
 *  and never converts through a timezone. */
export interface InputDateNode {
	type: 'input-date';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the picker. */
	label: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the picker. */
	helper?: string;
}

/** Select input node — renders a dropdown select. */
export interface InputSelectNode {
	type: 'input-select';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the select. */
	label: string;
	/** The list of options to pick from. */
	options: { value: string; label: string }[];
	/** Placeholder text shown when no option is selected. */
	placeholder?: string;
	/** Whether the field is required. */
	required?: boolean;
}

/** Toggle input node — renders an on/off switch. */
export interface InputToggleNode {
	type: 'input-toggle';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed next to the toggle. */
	label: string;
}

/** Long text input node — renders a textarea (placeholder for a markdown editor). */
export interface InputLongtextNode {
	type: 'input-longtext';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the textarea. */
	label: string;
	/** Placeholder text shown when empty. */
	placeholder?: string;
}

/** Reference input node — renders a ReferencePicker for selecting a referenced document. */
export interface InputReferenceNode {
	type: 'input-reference';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the picker. */
	label: string;
	/** Qualified target doctype (e.g. "crm.Company") — when set, locks the type picker. */
	doctype?: string;
	/** Allowed qualified doctypes (constrained mode). */
	doctypes?: string[];
	/** Placeholder text shown in the search input. */
	placeholder?: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the picker. */
	helper?: string;
}

/** Email node — renders a clickable email capsule with copy-to-clipboard. */
export interface EmailNode {
	type: 'email';
	/** The email address (supports `$field` interpolation). */
	href: string;
	/** The display label (supports `$field` interpolation). */
	label: string;
}

/** File input node — renders an uploader for a `file`-typed doctype field.
 *
 *  The bound value in the document is the bare artifact id (a 26-char ULID).
 *  The component uploads the raw bytes to `POST /Api/core/artifacts` (the
 *  standalone upload route, bound to the uploading account) and writes the
 *  returned id into `values[field]`. On save, `Document::Update` records the
 *  artifact reference and appends an `artifact_owners` row via the re-attach
 *  flow (`Artifact::Owners.append_readable_for_document`). */
/** Money input node — edits a `money`-typed field as a decimal string + currency ticker.
 *
 *  The bound `values[field]` is the composite money object `{ value: string, currency: string }`
 *  expected by the backend's `MoneyType`. `value` is the canonical decimal string
 *  (never a JS number). The currency list and the default currency are not
 *  template-author props — they come from the doctype field definition's
 *  declared `currency` (a backfill hint) and the shared currency registry. */
export interface InputMoneyNode {
	type: 'input-money';
	/** The document field key this input binds to (must be a `money`-typed field). */
	field: string;
	/** Label displayed above the input. */
	label: string;
	/** Placeholder text shown in the amount input when empty. */
	placeholder?: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the input. */
	helper?: string;
}

/** Color input node — renders a color picker for a `color`-typed doctype field.
 *
 *  The bound value is a hex string (e.g. `#5B8DEF`). The component wraps the
 *  honeycomb `ColorInput` picker and a hex fallback field. */
export interface InputColorNode {
	type: 'input-color';
	/** The document field key this input binds to (must be a `color`-typed field). */
	field: string;
	/** Label displayed above the input. */
	label: string;
	/** Placeholder text shown when empty. */
	placeholder?: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the input. */
	helper?: string;
}

/** File input node — renders an uploader for a `file`-typed doctype field.
 *
 *  The bound value in the document is the bare artifact id (a 26-char ULID).
 *  The component uploads the raw bytes to `POST /Api/core/artifacts` (the
 *  standalone upload route, bound to the uploading account) and writes the
 *  returned id into `values[field]`. On save, `Document::Update` records the
 *  artifact reference and appends an `artifact_owners` row via the re-attach
 *  flow (`Artifact::Owners.append_readable_for_document`). */
export interface InputFileNode {
	type: 'input-file';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the uploader. */
	label: string;
	/** Placeholder text shown when no file is attached. */
	placeholder?: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the uploader. */
	helper?: string;
}

/** Secret input node — renders a stage-and-store control for a `secret`-typed doctype field.
 *
 *  The bound value in the form is a stage handle returned by
 *  `POST /Api/secrets/stage`; the document content itself only ever carries
 *  the `{mode, version, set_at}` marker the backend persists at save time.
 *  The plaintext lives in a local, cleared-after-staging input and is never
 *  written into the values bag. */
export interface InputSecretNode {
	type: 'input-secret';
	/** The document field key this input binds to. */
	field: string;
	/** Label displayed above the control. */
	label: string;
	/** Placeholder text shown in the empty password input. */
	placeholder?: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the control. */
	helper?: string;
}

/** List input node — edits an `array`-of-string-typed field as a chip list.
 *
 *  The bound `values[field]` is a `string[]`. The backend's `ArrayType`
 *  validates each element against the declared `items` type, so the field
 *  must be an array of string-like scalars; object-item arrays need an
 *  `array` node with child inputs instead. */
export interface InputListNode {
	type: 'input-list';
	/** The document field key this input binds to (an array-of-string field). */
	field: string;
	/** Label displayed above the editor. */
	label: string;
	/** Placeholder text shown in the empty add-value input. */
	placeholder?: string;
	/** Whether the field is required. */
	required?: boolean;
	/** Helper text displayed below the editor. */
	helper?: string;
}

/** Body of `POST /Api/secrets/stage`.
 *
 *  `value` is the plaintext for `hash`/`sealed` modes and must be absent for
 *  `token` mode; `doc_id` is sent only when the form edits a persisted
 *  document. The response is `{handle, token?}` — `token` is present only in
 *  token mode and is shown once. */
export interface SecretStagePayload {
	domain: string;
	doctype: string;
	field_path: string;
	value?: string;
	doc_id?: string;
}

/** All valid template node types. */
export type TemplateNode =
	| TabsNode
	| LabelNode
	| FieldNode
	| MarkdownNode
	| ObjectNode
	| IfNode
	| ArrayNode
	| DictNode
	| GridNode
	| ColNode
	| ImageNode
	| ImageArtifactNode
	| LinkNode
	| TitleNode
	| CapsuleNode
	| HrNode
	| EmailNode
	| InputAutoNode
	| InputTextNode
	| InputDatetimeNode
	| InputPeriodNode
	| InputDateperiodNode
	| InputDateNode
	| InputSelectNode
	| InputToggleNode
	| InputLongtextNode
	| InputReferenceNode
	| InputMoneyNode
	| InputColorNode
	| InputFileNode
	| InputSecretNode
	| InputListNode
	| RelationNode
	| HeaderNode
	| SectionNode
	| SidebarNode
	| RecordMetaNode
	| RowNode;

/** Result of `isReferenceField` (`./template-resolve`) — describes a `$field` reference value. */
export interface ReferenceFieldMatch {
	/** The doctype field key (without the leading `$`). */
	fieldKey: string;
	/** Qualified target doctype, e.g. `"crm.Deal"`. */
	qualifiedDoctype: string;
}

/** Payload emitted by a Capsule rendered for a hydrated reference field. */
export interface ReferenceClickEvent {
	/** Referenced document's domain (e.g. `"crm"`). */
	domain: string;
	/** Referenced document's doctype (e.g. `"Company"`). */
	doctype: string;
	/** Referenced document's full qualified id (e.g. `"crm.Company.1"`). */
	id: string;
}

/** Click handler for hydrated reference capsules. Wired by `ListView`'s
 *  QuickView so clicking a reference capsule switches the preview to the
 *  referenced document (loading its doctype's `quickView` template). */
export type ReferenceClickHandler = (e: ReferenceClickEvent) => void;

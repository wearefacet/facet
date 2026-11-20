// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Client-side UI tools — tool calls whose real effect happens in the chat UI,
 * not on the backend.
 *
 * The backend registers `preview_view` and `go_to_page` on domain-builder
 * conversations (`src/assistant/domain_builder/tools/ui_tools.cr`); their
 * callbacks only validate and ack. The chat UI intercepts the resolved
 * `tool_call` chunk and renders the matching surface (`ViewPreviewCard`) or
 * navigates the builder.
 *
 * Two wire paths carry the arguments to the UI:
 * - Live stream: the `tool_call` SSE chunk carries `arguments` for UI tool
 *   names only (`Stream::ToolTraceHandler#argument_tools`).
 * - Replay: persisted `ToolCallRef.arguments` inside
 *   `agent_turns.response_messages` — so previews survive a reload.
 */
import type { StreamChunk } from '../driver/types.js';

/**
 * The preview template tree, as persisted on `preview_view` arguments. The
 * main application types it with its template grammar
 * (`frontend/src/lib/template-types.ts`); the package renders no preview
 * cards (the app assistant mounts no UI tools), so a structural record is
 * enough — the parser only validates shape and carries the payload through.
 */
export type TemplateNode = Record<string, unknown>;

/** Collection-view config shape (table columns or calendar fields). The
 * package renders no calendar surfaces; kept structural for the same reason
 * as {@link TemplateNode}. */
export type CalendarViewConfig = Record<string, unknown>;

/**
 * Tool names whose chunks carry the raw `arguments` JSON — the union of the
 * two backend UI-tool sets (`DomainBuilder::Registrar::UI_TOOL_NAMES` and
 * `Assistant::Workspace::Registrar::UI_TOOL_NAMES`). Each kind forwards only
 * its own set on the wire; the workspace tools render or navigate in the main
 * application (see `isWorkspaceNavigateChunk`, `parseShowDocuments`).
 */
export const UI_TOOL_NAMES: readonly string[] = [
	'preview_view',
	'go_to_page',
	'navigate',
	'show_documents'
];

/** Builder pages the `go_to_page` tool can navigate to. */
export type BuilderPage = 'overview' | 'doctypes' | 'check' | 'grants' | 'doctype' | 'preview';

/** Parsed `preview_view` arguments (the part carries the live status). */
export interface ViewPreviewSpec {
	kind: 'document' | 'collection';
	/** `kind === 'document'` — the template node tree. */
	template?: TemplateNode;
	/** `kind === 'collection'` — listing surface. */
	surface?: 'table' | 'calendar';
	/** Collection view config: table columns or a calendar config. */
	config?: {
		columns?: { key: string; label?: string; width?: string }[];
	} & Partial<CalendarViewConfig>;
	/** Model-provided plausible field values; the UI generates the rest. */
	sample_data?: Record<string, unknown>;
	/** Card title. */
	title?: string;
}

/**
 * Parses and validates raw `preview_view` arguments. Returns `null` when the
 * payload is missing, not valid JSON, or does not satisfy the tool contract —
 * the caller then falls back to rendering a plain tool-call bar.
 */
export function parseViewPreview(argsJson: string | undefined): ViewPreviewSpec | null {
	if (!argsJson) return null;
	let raw: Record<string, unknown>;
	try {
		const parsed: unknown = JSON.parse(argsJson);
		if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null;
		raw = parsed as Record<string, unknown>;
	} catch {
		return null;
	}

	if (raw['kind'] !== 'document' && raw['kind'] !== 'collection') return null;

	const spec: ViewPreviewSpec = { kind: raw['kind'] };
	if (spec.kind === 'document') {
		const template = raw['template'];
		if (typeof template !== 'object' || template === null || Array.isArray(template)) return null;
		spec.template = template as TemplateNode;
	} else {
		const surface = raw['surface'];
		if (surface !== 'table' && surface !== 'calendar') return null;
		spec.surface = surface;
		const config = raw['config'];
		if (typeof config === 'object' && config !== null && !Array.isArray(config)) {
			spec.config = config as ViewPreviewSpec['config'];
		}
	}
	if (typeof raw['sample_data'] === 'object' && raw['sample_data'] !== null) {
		spec.sample_data = raw['sample_data'] as Record<string, unknown>;
	}
	if (typeof raw['title'] === 'string' && raw['title'].length > 0) {
		spec.title = raw['title'];
	}
	return spec;
}

export interface GoToPageArgs {
	page: BuilderPage;
	doctype_id?: string;
	tab?: string;
	path?: string[];
}

const GO_TO_PAGES: readonly BuilderPage[] = [
	'overview',
	'doctypes',
	'check',
	'grants',
	'doctype',
	'preview'
];

/**
 * Parses raw `go_to_page` arguments. Returns `null` when the payload is
 * missing, invalid, or names an unknown page.
 */
export function parseGoToPage(argsJson: string | undefined): GoToPageArgs | null {
	if (!argsJson) return null;
	let raw: Record<string, unknown>;
	try {
		const parsed: unknown = JSON.parse(argsJson);
		if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null;
		raw = parsed as Record<string, unknown>;
	} catch {
		return null;
	}

	const page = raw['page'];
	if (typeof page !== 'string' || !GO_TO_PAGES.includes(page as BuilderPage)) return null;
	const out: GoToPageArgs = { page: page as BuilderPage };
	if (typeof raw['doctype_id'] === 'string' && raw['doctype_id'].length > 0) {
		out.doctype_id = raw['doctype_id'];
	}
	if (typeof raw['tab'] === 'string' && raw['tab'].length > 0) {
		out.tab = raw['tab'];
	}
	if (
		Array.isArray(raw['path']) &&
		raw['path'].every((seg) => typeof seg === 'string' && seg.length > 0)
	) {
		out.path = raw['path'] as string[];
	}
	return out;
}

/** True when a chunk is the resolved `go_to_page` call — the live-stream
 * navigation trigger (replay must not re-navigate). */
export function isNavigateChunk(chunk: StreamChunk): chunk is StreamChunk & {
	kind: 'tool_call';
	name: 'go_to_page';
	status: 'ok';
	arguments: string;
} {
	return (
		chunk.kind === 'tool_call' &&
		chunk.name === 'go_to_page' &&
		chunk.status === 'ok' &&
		typeof chunk.arguments === 'string'
	);
}

// ── Workspace UI tools ────────────────────────────────────────────────────

/** Target kinds the workspace `navigate` tool can open. */
export type NavigateTargetKind = 'document' | 'collection' | 'domain';

/**
 * Parsed `navigate` arguments — mirrors
 * `Assistant::Workspace::Registrar.register_navigate`'s payload:
 * `{target, domain, doctype?, id?, view_slug?}`.
 */
export interface NavigateTargetArgs {
	target: NavigateTargetKind;
	domain: string;
	/** Document and collection targets. */
	doctype?: string;
	/** Document target only. */
	id?: string;
	/** Collection target only — the collection view tab to open. */
	view_slug?: string;
}

/**
 * Parses raw `navigate` arguments. Returns `null` when the payload is
 * missing, not valid JSON, or breaks the tool contract — the caller then
 * keeps the plain tool-call bar (there is nothing to open).
 */
export function parseNavigateTarget(argsJson: string | undefined): NavigateTargetArgs | null {
	if (!argsJson) return null;
	let raw: Record<string, unknown>;
	try {
		const parsed: unknown = JSON.parse(argsJson);
		if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null;
		raw = parsed as Record<string, unknown>;
	} catch {
		return null;
	}

	const target = raw['target'];
	const domain = raw['domain'];
	if (target !== 'document' && target !== 'collection' && target !== 'domain') return null;
	if (typeof domain !== 'string' || domain.length === 0) return null;

	const out: NavigateTargetArgs = { target, domain };
	if (target === 'domain') return out;

	const doctype = raw['doctype'];
	if (typeof doctype !== 'string' || doctype.length === 0) return null;
	out.doctype = doctype;

	if (target === 'document') {
		const id = raw['id'];
		if (typeof id !== 'string' || id.length === 0) return null;
		out.id = id;
		return out;
	}

	const viewSlug = raw['view_slug'];
	if (viewSlug === null || viewSlug === undefined) return out;
	if (typeof viewSlug !== 'string' || viewSlug.length === 0) return null;
	out.view_slug = viewSlug;
	return out;
}

/** True when a chunk is the resolved workspace `navigate` call — the
 * live-stream navigation trigger (replay must not re-navigate). */
export function isWorkspaceNavigateChunk(chunk: StreamChunk): chunk is StreamChunk & {
	kind: 'tool_call';
	name: 'navigate';
	status: 'ok';
	arguments: string;
} {
	return (
		chunk.kind === 'tool_call' &&
		chunk.name === 'navigate' &&
		chunk.status === 'ok' &&
		typeof chunk.arguments === 'string'
	);
}

/** Parsed `show_documents` arguments — mirrors
 * `Assistant::Workspace::Registrar.register_show_documents`'s payload.
 * `ids` holds the document ids the model asked to show. */
export interface ShowDocumentsArgs {
	domain: string;
	doctype: string;
	ids: string[];
	display: 'card' | 'inline';
}

/** Ack payload of a successful `show_documents` call: the ids that are
 * readable (and will render) and the ones dropped — without the reason. */
interface ShowDocumentsAck {
	rendered?: unknown;
}

/** Tool envelope plus its data half — the shape a resolved chunk's
 * `result` string carries for every workspace tool callback. */
interface ToolEnvelope {
	ok?: unknown;
	data?: ShowDocumentsAck;
}

/**
 * Parses `show_documents` arguments into the ids to render. When the tool's
 * ack result parses (the same chunk carries it), the ids narrow to the
 * `rendered` list — the readable subset the backend accepted. Returns
 * `null` when the arguments break the tool contract; the caller falls back
 * to a plain tool-call bar.
 */
export function parseShowDocuments(
	argsJson: string | undefined,
	resultJson?: string
): ShowDocumentsArgs | null {
	if (!argsJson) return null;
	let raw: Record<string, unknown>;
	try {
		const parsed: unknown = JSON.parse(argsJson);
		if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null;
		raw = parsed as Record<string, unknown>;
	} catch {
		return null;
	}

	const domain = raw['domain'];
	const doctype = raw['doctype'];
	const ids = raw['ids'];
	if (typeof domain !== 'string' || domain.length === 0) return null;
	if (typeof doctype !== 'string' || doctype.length === 0) return null;
	if (!Array.isArray(ids) || ids.length === 0) return null;
	if (!ids.every((id) => typeof id === 'string' && id.length > 0)) return null;

	const display = raw['display'] ?? 'card';
	if (display !== 'card' && display !== 'inline') return null;

	let rendered = ids as string[];
	if (resultJson) {
		try {
			const envelope = JSON.parse(resultJson) as ToolEnvelope;
			const ack = envelope && typeof envelope === 'object' ? envelope.data : undefined;
			if (
				ack &&
				typeof ack === 'object' &&
				Array.isArray(ack['rendered']) &&
				ack['rendered'].every((id) => typeof id === 'string')
			) {
				const set = new Set(ack['rendered'] as string[]);
				// Keep the argument order; drop ids the backend skipped.
				rendered = (ids as string[]).filter((id) => set.has(id));
				if (rendered.length === 0) return null;
			}
		} catch {
			/* No parseable ack — render the requested ids; the card's own
			   error state covers an unreadable one. */
		}
	}

	return { domain, doctype, ids: rendered, display };
}

// ── Fake data generation ───────────────────────────────────────────────────

/**
 * Collects the `$field` tokens referenced by a template tree, in
 * first-appearance order. Only tokens the preview generator can fill get a
 * value; anything the model supplied via `sample_data` wins.
 *
 * Scope-internal tokens are excluded: `$value` (the scalar-array item
 * binding), `$item` / `$this` / `$self` / `$index` / `$key` / `$page`
 * (wrapper scopes) and `parent.*` paths never resolve against the top-level
 * document, so faking them would mask an unbound token as a working binding.
 */
const SCOPE_TOKENS = new Set(['value', 'item', 'this', 'self', 'index', 'key', 'page']);

export function templateFieldKeys(template: TemplateNode): string[] {
	const keys = new Set<string>();
	const walk = (node: unknown): void => {
		if (typeof node !== 'object' || node === null) return;
		const rec = node as Record<string, unknown>;
		for (const value of Object.values(rec)) {
			if (typeof value === 'string' && value.startsWith('$')) {
				keys.add(value.slice(1));
			} else if (
				typeof value === 'string' &&
				Object.prototype.hasOwnProperty.call(rec, 'field') &&
				value === rec['field'] &&
				!value.startsWith('$')
			) {
				// `field`-carrying nodes (object/array/dict/if/relation) scope or
				// iterate data — their fields resolve from the document too.
				keys.add(value);
			}
			if (Array.isArray(value)) {
				value.forEach(walk);
			} else if (typeof value === 'object' && value !== null) {
				walk(value);
			}
		}
	};
	walk(template);
	return [...keys].filter((k) => !k.startsWith('parent.') && !SCOPE_TOKENS.has(k));
}

/** Fallback fake values, keyed by field-name heuristics. Deliberately
 * deterministic (hash-driven) so a re-render of the same template shows the
 * same values — no flicker on scroll. */
const FAKE_WORDS = [
	'Aurora',
	'Northwind',
	'Summit',
	'Bluebird',
	'Harbor',
	'Meridian',
	'Cascade',
	'Riverside',
	'Goldenrod',
	'Lakeshore'
];

function hashString(s: string): number {
	let h = 0;
	for (let i = 0; i < s.length; i++) {
		h = (h * 31 + s.charCodeAt(i)) | 0;
	}
	return Math.abs(h);
}

/** Generates a plausible fake value for one field key. */
export function fakeFieldValue(key: string): unknown {
	const k = key.toLowerCase();
	const h = hashString(key);
	const word = (i: number) => FAKE_WORDS[Math.abs(i) % FAKE_WORDS.length] ?? FAKE_WORDS[0]!;
	if (k.endsWith('_id')) return `core.doc_${word(h).toLowerCase()}`;
	if (k.includes('email')) return 'jordan.smith@example.com';
	if (k.includes('phone')) return '+1 555 0100';
	if (k.includes('website') || k.includes('url')) return 'https://example.com';
	if (k.includes('date') || k.endsWith('_at')) return '2026-03-17T09:00:00Z';
	if (
		k.includes('amount') ||
		k.includes('price') ||
		k.includes('total') ||
		k.includes('cost') ||
		k.includes('balance') ||
		k.includes('salary')
	) {
		return { value: (1250 + (h % 90) * 10).toFixed(2), currency: 'USD' };
	}
	if (k.includes('status') || k.includes('state') || k.includes('priority')) return 'active';
	if (
		k.includes('count') ||
		k.includes('qty') ||
		k.includes('quantity') ||
		k.includes('level') ||
		k.includes('score') ||
		k.includes('points') ||
		k.includes('age')
	) {
		return (h % 40) + 1;
	}
	if (k.startsWith('is_') || k.startsWith('has_') || k.endsWith('_flag') || k === 'active') {
		return true;
	}
	return `${word(h)} ${word(h >> 3)}`;
}

/**
 * Builds the fake document a document-kind preview renders against: the
 * model's `sample_data` merged over generated values for every `$field` the
 * template references.
 */
export function buildPreviewDocument(spec: ViewPreviewSpec): {
	data: Record<string, unknown>;
	sampleFields: string[];
} {
	const data: Record<string, unknown> = {};
	if (spec.template) {
		for (const key of templateFieldKeys(spec.template)) {
			data[key] = fakeFieldValue(key);
		}
	}
	for (const [k, v] of Object.entries(spec.sample_data ?? {})) {
		data[k] = v;
	}
	return { data, sampleFields: Object.keys(data) };
}

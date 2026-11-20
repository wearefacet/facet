// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * ref-chip — the inline atom node behind mention and document-reference
 * chips in the Milkdown editor. One node for both kinds: the kind derives
 * from the URN (an `iam.Account` URN renders the mention chip, any other
 * document URN the docref chip).
 *
 * The stored markdown does not change — a chip is still
 * `[@Label](urn:facet:…)`. The node only changes the in-editor
 * representation: one atom node, one position boundary, no hidden text.
 * The remark rules keep that round-trip byte-compatible: `parseMarkdown`
 * claims mdast `link` nodes whose URL is a chip-shaped `urn:facet:` URN
 * (every node spec beats every mark spec in the transformer, so the
 * commonmark link mark never sees them); `toMarkdown` emits the same link
 * back. Artifact URNs and state-pinned URNs (`…?state=…`) are not chips —
 * they keep their own rendering (capsule decoration / plain link).
 *
 * Click contract:
 *
 * - Write (edit): a chip click creates a `NodeSelection` (ProseMirror's
 *   default for selectable atoms) — typing replaces the chip, Backspace
 *   removes it whole. It never opens the QuickView.
 * - Preview / readonly: a chip click emits the reference event to the
 *   host (`onReferenceClick` — the QuickView drawer). With no handler the
 *   chip stays static — no navigation fallback.
 */

import { $nodeSchema, $view } from '@milkdown/kit/utils';
import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node as ProseNode } from '@milkdown/kit/prose/model';
import type { NodeView } from '@milkdown/kit/prose/view';
import type { MarkdownNode } from '@milkdown/kit/transformer';
import * as m from '$lib/paraglide/messages';
import { parseAccountUrn } from '$lib/mentions.js';
import { parseDocUrn, type ChipResolution, type DocUrn } from '$lib/docrefs.js';
import type { ReferenceClickHandler } from '$lib/template-types';

/**
 * Resolution cache + pub-sub the chip node views render from. The editor
 * component owns the cache (live labels resolve through `sources`) and
 * exposes it to the plugin factory; a resolution or a doctype-tint load
 * notifies the subscribed node views.
 */
export type RefChipStore = {
	/** The resolved state of one chip URN, or `undefined` before it lands. */
	resolution(urn: string): ChipResolution | undefined;
	/** Schedules the live-label resolution for a URN once (dedup inside). */
	ensure(urn: string, ref: { domain: string; doctype: string; id: string }): void;
	/** Subscribes a node view to resolution/tint updates for one URN. */
	subscribe(urn: string, cb: () => void): () => void;
};

/** Closures the chip node views read at call time — the editor component
 *  owns the current values, the plugins outlive none of them. */
export type RefChipDeps = {
	store: RefChipStore;
	/** The Milkdown `readonly` prop — read live at render and click time. */
	isReadonly: () => boolean;
	/** The host's reference-click handler (the QuickView), or undefined. */
	onReferenceClick: () => ReferenceClickHandler | undefined;
	/** Initials for the mention avatar (the picker's rule). */
	initialsOf: (label: string) => string;
	/** Doctype tint for the docref dot (`domain.Doctype` → colour). */
	docrefColor: (qualified: string) => string | undefined;
};

/** A chip-shaped URN: an `iam.Account` mention or a colon-form document
 *  URN. Artifact URNs (four segments) and state-pinned URNs (`…?state=…`)
 *  parse as null on both halves — they are not chips. */
function isChipUrn(href: string): boolean {
	return parseAccountUrn(href) !== null || parseDocUrn(href) !== null;
}

/** Flattens a link label's mdast children to plain text. The picker
 *  inserts plain labels; emphasis inside a hand-written label degrades to
 *  text (an image contributes its alt). */
function labelOf(node: MarkdownNode): string {
	if (node.type === 'text') return typeof node.value === 'string' ? node.value : '';
	if (node.type === 'image') return typeof node.alt === 'string' ? node.alt : '';
	const children = node.children;
	if (!Array.isArray(children)) return '';
	return children.map(labelOf).join('');
}

/** The display label and state class of one chip — the live-label rule.
 *  States: `ok` (live title), `deleted` 404/410 (stored text, struck
 *  through), `forbidden` 403 (never render the stored title — it may leak
 *  information to a viewer who lost access), `unknown`/unresolved (stored
 *  text, neutral style; mentions stay plain until resolution lands). An
 *  empty stored label falls back to the URN for display; the stored label
 *  itself stays as-is. */
function chipRenderState(
	urn: string,
	storedLabel: string,
	accountId: string | null,
	store: RefChipStore
): { label: string; stateClass: string } {
	const stored = storedLabel || urn;
	const resolution = store.resolution(urn);
	let label = stored;
	let stateClass = 'md-chip-unknown';
	if (resolution) {
		if (resolution.status === 'ok') {
			label = accountId ? `@${resolution.label}` : resolution.label;
			stateClass = '';
		} else if (resolution.status === 'deleted') {
			stateClass = 'md-chip-deleted';
		} else if (resolution.status === 'forbidden') {
			// Never render the stored title — it may leak information.
			label = m.doc_md_ref_restricted();
			stateClass = 'md-chip-forbidden';
		}
	} else if (accountId) {
		stateClass = '';
	}
	return { label, stateClass };
}

/**
 * The chip node view. Renders the same DOM contract the stories and CSS
 * know (`.md-mention-chip` / `.md-docref-chip`, avatar/dot + label,
 * `data-account-id` / `data-doc-uri`, the resolution state class) and
 * re-renders on attribute changes and store notifications. The view owns
 * every DOM change inside the chip, so mutations are ignored; events are
 * left to ProseMirror (a mousedown on the atom creates the NodeSelection
 * in edit mode).
 */
function createRefChipNodeView(initialNode: ProseNode, deps: RefChipDeps): NodeView {
	const dom = document.createElement('span');
	let node = initialNode;
	let urn = String(node.attrs.href ?? '');
	// Hoisted — the initial `subscribe` call below reads it.
	function render(): void {
		const href = String(node.attrs.href ?? '');
		const accountId = parseAccountUrn(href);
		const docRef = accountId ? null : parseDocUrn(href);
		const { label, stateClass } = chipRenderState(
			href,
			String(node.attrs.label ?? ''),
			accountId,
			deps.store
		);
		const mention = accountId !== null;
		dom.className = `${mention ? 'md-mention-chip' : 'md-docref-chip'}${stateClass ? ` ${stateClass}` : ''}`;
		if (mention) dom.setAttribute('data-account-id', accountId);
		else dom.removeAttribute('data-account-id');
		if (docRef) dom.setAttribute('data-doc-uri', href);
		else dom.removeAttribute('data-doc-uri');
		if (deps.isReadonly()) {
			// Readonly chips open the QuickView — label the affordance.
			dom.title = label;
			dom.setAttribute('aria-label', label);
		} else {
			dom.removeAttribute('title');
			dom.removeAttribute('aria-label');
		}
		dom.replaceChildren();
		if (mention) {
			const avatar = document.createElement('span');
			avatar.className = 'md-chip-avatar';
			avatar.textContent = deps.initialsOf(label);
			dom.appendChild(avatar);
		} else {
			const dot = document.createElement('span');
			dot.className = 'md-chip-dot';
			const color = docRef ? deps.docrefColor(`${docRef.domain}.${docRef.doctype}`) : undefined;
			if (color) dot.style.background = color;
			dom.appendChild(dot);
		}
		const labelEl = document.createElement('span');
		labelEl.className = 'md-chip-label';
		labelEl.textContent = label;
		dom.appendChild(labelEl);
		const ref: { domain: string; doctype: string; id: string } | null = accountId
			? { domain: 'iam', doctype: 'Account', id: accountId }
			: docRef;
		if (ref) deps.store.ensure(href, ref);
	}

	let unsubscribe = deps.store.subscribe(urn, render);
	render();

	dom.addEventListener('click', (e) => {
		// Edit mode: ProseMirror's own mousedown selects the atom — a chip
		// click never opens the QuickView there.
		if (!deps.isReadonly()) return;
		const handler = deps.onReferenceClick();
		if (!handler) return; // No handler — the chip stays static.
		const href = String(node.attrs.href ?? '');
		const accountId = parseAccountUrn(href);
		const ref: DocUrn | { domain: string; doctype: string; id: string } | null = accountId
			? { domain: 'iam', doctype: 'Account', id: accountId }
			: parseDocUrn(href);
		if (!ref) return;
		e.preventDefault();
		handler(ref);
	});

	return {
		dom,
		update(newNode: ProseNode): boolean {
			if (newNode.type.name !== 'ref_chip') return false;
			node = newNode;
			const nextUrn = String(newNode.attrs.href ?? '');
			if (nextUrn !== urn) {
				unsubscribe();
				urn = nextUrn;
				unsubscribe = deps.store.subscribe(urn, render);
			}
			render();
			return true;
		},
		// Every mutation inside the chip DOM is the view's own work (label
		// resolution, tint updates) — none of it is an editor edit.
		ignoreMutation: () => true,
		destroy() {
			unsubscribe();
		}
	};
}

/**
 * The schema is a module-level singleton (the presets precedent — ctx
 * values are per-editor even when the plugin object is shared); the view
 * binds this instance's deps, so the factory runs per editor component.
 */
const refChipSchema = $nodeSchema('ref_chip', () => ({
	group: 'inline',
	inline: true,
	atom: true,
	selectable: true,
	// No marks on the chip — the label lives in the `label` attribute.
	marks: '',
	attrs: {
		// Canonical colon-form URN — unsanitized (the SAFE_PROTOCOLS
		// sanitizer only touches link marks).
		href: { default: '' },
		// Stored label — the mention keeps the `@` glyph. Round-trips.
		label: { default: '' }
	},
	parseDOM: [
		{
			// External HTML — a markdown-rendered anchor that kept the URN href.
			tag: 'a[href^="urn:facet:"]',
			// Above the commonmark link mark (`a[href]` at the default 50):
			// DOMParser.schemaRules inserts mark rules before node rules at
			// equal priority, so the link mark would win and the chip would
			// parse as plain link text. `getAttrs` returning false skips the
			// rule — artifact and state-pinned URNs keep the link mark.
			priority: 100,
			getAttrs: (dom) => {
				if (!(dom instanceof HTMLElement)) return false;
				const href = dom.getAttribute('href') ?? '';
				if (!isChipUrn(href)) return false;
				return { href, label: dom.textContent ?? '' };
			}
		},
		{
			// The editor's own copy output (the `toDOM` span below rides the
			// HTML clipboard half — the markdown serializer is only consulted
			// for text slices, so an atom chip copies as its toDOM markup).
			tag: 'span.md-ref-chip[data-urn]',
			priority: 100,
			getAttrs: (dom) => {
				if (!(dom instanceof HTMLElement)) return false;
				const href = dom.getAttribute('data-urn') ?? '';
				if (!isChipUrn(href)) return false;
				return { href, label: dom.getAttribute('data-label') ?? '' };
			}
		}
	],
	// Fallback rendering without the node view — and the source of the copy
	// serialization (ProseMirror's clipboard DOM path uses toDOM, not the
	// node view), which the `span[data-urn]` parse rule reads back.
	toDOM: (node) => [
		'span',
		{
			class: 'md-ref-chip',
			'data-urn': node.attrs.href,
			'data-label': node.attrs.label
		}
	],
	parseMarkdown: {
		match: (node) => node.type === 'link' && typeof node.url === 'string' && isChipUrn(node.url),
		runner: (state, node, type) => {
			const href = typeof node.url === 'string' ? node.url : '';
			state.addNode(type, { href, label: labelOf(node) });
		}
	},
	toMarkdown: {
		match: (node) => node.type.name === 'ref_chip',
		runner: (state, node) => {
			state.addNode('link', [{ type: 'text', value: String(node.attrs.label ?? '') }], undefined, {
				url: String(node.attrs.href ?? ''),
				title: null
			});
		}
	}
}));

/**
 * Builds the plugins to `.use()` on the editor before `create()`: the
 * `ref_chip` node schema and its node view. Deps are closures read at
 * call time — the component keeps the live values.
 */
export function createRefChipPlugins(deps: RefChipDeps): MilkdownPlugin[] {
	const refChipView = $view(refChipSchema.node, () => (node) => createRefChipNodeView(node, deps));
	// The schema spreads into its two plugins (ctx slice + node) — the tuple
	// form flattens at runtime but does not satisfy `MilkdownPlugin[]`.
	return [...refChipSchema, refChipView];
}

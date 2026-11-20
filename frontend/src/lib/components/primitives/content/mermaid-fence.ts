// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * mermaid-fence — the ProseMirror node view that renders a
 * ` ```mermaid ` fenced code block as a diagram inside the Milkdown editor.
 *
 * The stored markdown does not change: the fence stays a plain code block
 * (` ```mermaid ` + source). Crepe already parses it into a `code_block`
 * node whose `language` attribute is `mermaid`, and its own serializer
 * writes the fence back — so this file carries no schema and no
 * `toMarkdown` rule. A round-trip is byte-stable by construction.
 *
 * The node view replaces Crepe's CodeMirror code-block view for mermaid
 * fences only. Any other language returns `null`, and ProseMirror falls back
 * to Crepe's default view (language picker + highlighting). Both factories
 * ride the same `nodeViews.code_block` slot: registering a factory for a
 * node type replaces the earlier one, and returning `null` from the new
 * factory restores the default rendering.
 *
 * Two renderings:
 *
 * - Readonly (preview surfaces): the diagram replaces the source. The view
 *   owns the whole node DOM — no `contentDOM`, so ProseMirror renders the
 *   block as a leaf. This also gives `setNodeMarkup` a path to the view
 *   (ProseMirror only reaches a node view's `update` for a block with no
 *   `contentDOM`), which is how a language change re-creates the view.
 * - Edit (write): the node keeps its `contentDOM` — the source stays the
 *   editable ProseMirror text — and the diagram renders in a preview area
 *   below it. GitHub-style split, no selection heuristics.
 *
 * `MermaidDiagram` lazy-loads the `mermaid` chunk itself: a document without
 * a mermaid fence never builds the diagram component, and the chunk loads
 * only when the first diagram mounts.
 */

import { mount, unmount } from 'svelte';
import { $view } from '@milkdown/kit/utils';
import { codeBlockSchema } from '@milkdown/kit/preset/commonmark';
import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node as ProseNode } from '@milkdown/kit/prose/model';
import type { NodeView, NodeViewConstructor, EditorView } from '@milkdown/kit/prose/view';
import MermaidDiagram from './MermaidDiagram.svelte';

/** Mermaid renders are too costly to run per keystroke — the preview
 *  re-renders this long after the last edit to the source. */
const RENDER_DEBOUNCE_MS = 400;

/** Closures the node view reads at call time — the editor component keeps
 *  the live values (the `ref-chip` deps precedent). */
export type MermaidFenceDeps = {
	/** The Milkdown `readonly` prop — read live at node-view construction. */
	isReadonly: () => boolean;
};

/** The source text of a `code_block` node. */
function sourceOf(node: ProseNode): string {
	return node.textContent;
}

/**
 * Mounts the shared `MermaidDiagram` into a container. Svelte flushes a new
 * root effect synchronously (`component_root` runs it in place), so the
 * component's state is live before this returns.
 */
function mountDiagram(target: HTMLElement, source: string): ReturnType<typeof mount> {
	return mount(MermaidDiagram, { target, props: { source } });
}

/** One mounted diagram plus its re-render timer. */
type Diagram = { timer: ReturnType<typeof setTimeout> | null };

function createReadonlyView(node: ProseNode): NodeView {
	const dom = document.createElement('div');
	dom.className = 'md-mermaid';
	dom.setAttribute('data-mermaid-fence', '');
	const diagram: Diagram = { timer: null };
	const instance = mountDiagram(dom, sourceOf(node));
	return {
		dom,
		update(next: ProseNode): boolean {
			if (next.type !== node.type) return false;
			// A language change leaves the mermaid path — re-create the node
			// view so the default code-block rendering comes back.
			if (next.attrs.language !== 'mermaid') return false;
			node = next;
			const src = sourceOf(node);
			if (diagram.timer) clearTimeout(diagram.timer);
			diagram.timer = setTimeout(() => {
				diagram.timer = null;
				instance.$set({ source: src });
			}, RENDER_DEBOUNCE_MS);
			return true;
		},
		// The diagram DOM is the view's own work — never an editor edit.
		ignoreMutation: () => true,
		destroy() {
			if (diagram.timer) clearTimeout(diagram.timer);
			void unmount(instance);
		}
	};
}

function createEditView(node: ProseNode): NodeView {
	const dom = document.createElement('div');
	dom.className = 'md-mermaid md-mermaid-edit';
	dom.setAttribute('data-mermaid-fence', '');
	// The source half — ProseMirror renders the code block's text here.
	const contentDOM = document.createElement('div');
	contentDOM.className = 'md-mermaid-source';
	const preview = document.createElement('div');
	preview.className = 'md-mermaid-preview';
	preview.setAttribute('contenteditable', 'false');
	dom.append(contentDOM, preview);

	const diagram: Diagram = { timer: null };
	const instance = mountDiagram(preview, sourceOf(node));
	const schedule = (src: string) => {
		if (diagram.timer) clearTimeout(diagram.timer);
		diagram.timer = setTimeout(() => {
			diagram.timer = null;
			// One mounted component, a new source — the component's own effect
			// re-renders the diagram (it guards a redundant render).
			instance.$set({ source: src });
		}, RENDER_DEBOUNCE_MS);
	};

	return {
		dom,
		contentDOM,
		update(next: ProseNode): boolean {
			if (next.type !== node.type) return false;
			// A language change leaves the mermaid path — re-create the node
			// view so Crepe's code-block view takes the node back.
			if (next.attrs.language !== 'mermaid') return false;
			const changed = !next.eq(node);
			node = next;
			if (changed) schedule(sourceOf(node));
			return true;
		},
		// The preview half is the view's own work; the source half is
		// ProseMirror's editable content and must keep its mutations.
		ignoreMutation: (mutation) => !contentDOM.contains(mutation.target),
		destroy() {
			if (diagram.timer) clearTimeout(diagram.timer);
			void unmount(instance);
		}
	};
}

/** The `code_block` node-view factory. Non-mermaid fences fall through to
 *  Crepe's default code-block view (`null`). ProseMirror accepts `null` from
 *  a node-view constructor and renders the default DOM — the `NodeViewConstructor`
 *  type does not model that fallback, so the factory is cast once here. */
function createMermaidFenceView(deps: MermaidFenceDeps): NodeViewConstructor {
	const factory = (node: ProseNode, _view: EditorView): NodeView | null => {
		if (node.attrs.language !== 'mermaid') return null;
		return deps.isReadonly() ? createReadonlyView(node) : createEditView(node);
	};
	return factory as NodeViewConstructor;
}

/**
 * Builds the plugin to `.use()` on the editor before `create()`. It must
 * come after Crepe's CodeMirror feature (Crepe applies its features in the
 * constructor) — its factory claims the `code_block` slot. The `codeBlockView`
 * handle is Crepe's own (same package instance as the feature that registers
 * the default view), so both factories share one node type and the last
 * registration wins.
 */
export function createMermaidPlugins(deps: MermaidFenceDeps): MilkdownPlugin[] {
	// Register the commonmark schema's own context slices first — `$view`
	// resolves the node type through them at create time, and this import is
	// a separate module instance from the one Crepe boots with.
	return [...codeBlockSchema, $view(codeBlockSchema.node, () => createMermaidFenceView(deps))];
}

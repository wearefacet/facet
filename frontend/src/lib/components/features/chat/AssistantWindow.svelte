<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import ErrorBoundary from '$lib/components/primitives/surfaces/ErrorBoundary.svelte';
	import { Bot, X, Minus, Maximize2, Minimize2 } from '@lucide/svelte';
	import type { Snippet } from 'svelte';
	import {
		readAssistantCollapsed,
		writeAssistantCollapsed,
		readAssistantMaximized,
		writeAssistantMaximized,
		readAssistantWidth,
		writeAssistantWidth,
		readAssistantHeight,
		writeAssistantHeight,
		readAssistantBarX,
		writeAssistantBarX,
		readAssistantBarY,
		writeAssistantBarY,
		readAssistantBarWidth,
		writeAssistantBarWidth,
		BAR_WIDTH_MIN,
		WIN_WIDTH_MIN,
		WIN_HEIGHT_MIN
	} from './assistantWindowState.js';

	/**
	 * Floating assistant window — the shared shell for every assistant mount.
	 *
	 * Window chrome only: a draggable header with the title, an optional
	 * scope badge and the Maximize / Collapse / Close actions, edge/corner
	 * resize, and the persisted window state (collapsed, maximized, size).
	 * The body comes in through the `children` snippet — normally a
	 * `ChatPanel` mount, so each surface keeps its own conversation factory,
	 * page context and renderers while the window looks and behaves the
	 * same everywhere.
	 *
	 * Per the configure UX brief addendum: the assistant is a floating,
	 * collapsible window; open/collapse state persists in local session
	 * storage. The expanded window keeps its position session-local (to
	 * avoid monitor-/resize-induced drift); the collapsed bar persists its
	 * position and width, so it reopens where the user left it. The window
	 * is `position: fixed` with a bottom-right default inset.
	 */

	let {
		/** Header title — the configured assistant name on both mounts. */
		title = m.assistant_title(),
		/** Scope badge in the header, e.g. the builder draft domain. Omitted
		 * on surfaces with no scope to show. */
		badge = undefined,
		/** Called when the user clicks the close (X) button. */
		onclose = undefined,
		/** The surface body — normally a `ChatPanel` mount. */
		children
	}: {
		title?: string;
		badge?: string;
		onclose?: () => void;
		children: Snippet;
	} = $props();

	// ── Window state ──────────────────────────────────────────────────────────
	//
	// `collapsed` shrinks the window to just its header. `maximized` expands
	// it to fill the page minus a gap, overriding the floating position/size
	// until restored. Both persist in sessionStorage.

	let collapsed = $state(readAssistantCollapsed());

	// Persist only when the value actually changed; without the guard the effect
	// would write to sessionStorage on every render that re-evaluates
	// `collapsed` (e.g. an unrelated prop change), which is wasted work and
	// noisy against the storage budget.
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastCollapsed = collapsed;
	$effect(() => {
		if (collapsed !== lastCollapsed) {
			lastCollapsed = collapsed;
			writeAssistantCollapsed(collapsed);
		}
	});

	function toggleCollapse() {
		collapsed = !collapsed;
	}

	/**
	 * Escape minimizes the window — but only when the focus sits inside it
	 * (the composer, the header controls), so the key never fights dialogs
	 * or other surfaces. `stopPropagation` keeps the global shortcut
	 * dispatcher out: minimizing consumes the Escape.
	 */
	function onWindowKeydown(e: KeyboardEvent) {
		if (e.key !== 'Escape') return;
		if (!collapsed) {
			collapsed = true;
			e.preventDefault();
		}
		e.stopPropagation();
	}

	let maximized = $state(readAssistantMaximized());

	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastMaximized = maximized;
	$effect(() => {
		if (maximized !== lastMaximized) {
			lastMaximized = maximized;
			writeAssistantMaximized(maximized);
		}
	});

	function toggleMaximize() {
		maximized = !maximized;
		// Maximize and restore always expand the full window — either button
		// click must never leave the collapsed title bar on screen.
		collapsed = false;
	}

	// Drag state. The expanded window's position is session-local; the
	// collapsed bar keeps its own persisted position (-1 = still unset —
	// the bar then sits docked at the bottom edge, at the window's x).
	const HEADER_HEIGHT = 40;
	let pos = $state({ x: -1, y: -1 });
	let barPos = $state({
		x: readAssistantBarX() ?? -1,
		y: readAssistantBarY() ?? -1
	});
	let dragging = $state(false);
	let dragOffset = $state({ x: 0, y: 0 });

	// Default inset: bottom-right window.
	const DEFAULT_RIGHT = 24;
	const DEFAULT_BOTTOM = 24;
	// Live viewport caps so a saved size never overflows a smaller screen.
	const MAX_WIDTH = $derived(
		typeof window === 'undefined' ? WIN_WIDTH_MIN : Math.max(WIN_WIDTH_MIN, window.innerWidth)
	);
	const MAX_HEIGHT = $derived(
		typeof window === 'undefined' ? WIN_HEIGHT_MIN : Math.max(WIN_HEIGHT_MIN, window.innerHeight)
	);
	// Gap from the viewport edges when maximized.
	const MAXIMIZED_GAP = 16;

	// User-resizable window width/height (persisted). Clamped live so the
	// window always fits the viewport and stays above the usable minimum.
	let winWidth = $state(readAssistantWidth());
	let winHeight = $state(readAssistantHeight());
	// Collapsed-bar width. `null` = unset — the bar inherits the window
	// width until the user resizes it; then it persists its own value.
	let barWidth = $state<number | null>(readAssistantBarWidth());

	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastWinWidth = winWidth;
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastWinHeight = winHeight;
	$effect(() => {
		if (winWidth !== lastWinWidth) {
			lastWinWidth = winWidth;
			writeAssistantWidth(winWidth);
		}
	});
	$effect(() => {
		if (winHeight !== lastWinHeight) {
			lastWinHeight = winHeight;
			writeAssistantHeight(winHeight);
		}
	});

	// Collapsed-bar position persists. The writes guard on a changed value,
	// so the seeded sentinel never stores a computed default — the bar
	// position lands in storage only after the user moves the bar.
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastBarX = barPos.x;
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastBarY = barPos.y;
	$effect(() => {
		if (barPos.x !== lastBarX) {
			lastBarX = barPos.x;
			writeAssistantBarX(barPos.x);
		}
		if (barPos.y !== lastBarY) {
			lastBarY = barPos.y;
			writeAssistantBarY(barPos.y);
		}
	});

	// Collapsed-bar width persists. `null` = unset — the bar keeps
	// inheriting the window width until the user resizes it.
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastBarWidth: number | null = barWidth;
	$effect(() => {
		if (barWidth !== lastBarWidth) {
			lastBarWidth = barWidth;
			if (barWidth !== null) writeAssistantBarWidth(barWidth);
		}
	});

	// Keep the window inside the viewport on resize so a saved size from a
	// larger monitor never overflows a smaller one, and the window never
	// gets lost off-screen if the browser shrinks.
	$effect(() => {
		const w = Math.max(WIN_WIDTH_MIN, Math.min(MAX_WIDTH, winWidth));
		const h = Math.max(WIN_HEIGHT_MIN, Math.min(MAX_HEIGHT, winHeight));
		if (w !== winWidth || h !== winHeight) {
			winWidth = w;
			winHeight = h;
		}
	});

	// Compute default position lazily — guard against SSR / undefined window.
	const initialPos = $derived.by(() => {
		if (typeof window === 'undefined') return { x: 0, y: 0 };
		return {
			x: window.innerWidth - winWidth - DEFAULT_RIGHT,
			y: window.innerHeight - winHeight - DEFAULT_BOTTOM
		};
	});

	// Current geometry. Collapsed wins over maximized — the minimized window
	// is the 40 px title bar. It starts docked at the bottom edge of the
	// viewport (same x and width as the floating window); a stored bar
	// position and width win instead and clamp on-screen. Letting the
	// maximized box win while the body is hidden would leave a full-size
	// empty surface. Otherwise maximized overrides the floating
	// position/size.
	const geometry = $derived.by(() => {
		if (typeof window === 'undefined') {
			return { x: 0, y: 0, width: winWidth, height: winHeight };
		}
		if (collapsed) {
			const width = Math.min(barWidth ?? winWidth, window.innerWidth);
			const x =
				barPos.x < 0
					? pos.x < 0
						? initialPos.x
						: pos.x
					: Math.max(0, Math.min(window.innerWidth - width, barPos.x));
			const y =
				barPos.y < 0
					? window.innerHeight - HEADER_HEIGHT - DEFAULT_BOTTOM
					: Math.max(0, Math.min(window.innerHeight - HEADER_HEIGHT, barPos.y));
			return { x, y, width, height: HEADER_HEIGHT };
		}
		if (maximized) {
			return {
				x: MAXIMIZED_GAP,
				y: MAXIMIZED_GAP,
				width: Math.max(0, window.innerWidth - MAXIMIZED_GAP * 2),
				height: Math.max(HEADER_HEIGHT, window.innerHeight - MAXIMIZED_GAP * 2)
			};
		}
		return {
			x: pos.x < 0 ? initialPos.x : pos.x,
			y: pos.y < 0 ? initialPos.y : pos.y,
			width: winWidth,
			height: winHeight
		};
	});

	// Initial position from the default; remains -1,-1 until effect primes it.
	$effect(() => {
		if (!maximized && pos.x < 0) pos = { ...initialPos };
	});

	function onDragStart(e: PointerEvent) {
		// The maximized window never drags — it is pinned to the viewport.
		// A collapsed bar stays draggable even then: collapsed wins in the
		// geometry, so the bar is the rendered surface, not the pinned box.
		if (maximized && !collapsed) return;
		// Only the header drag handle starts a drag; ignore clicks on the
		// buttons inside the header (they have their own onclick handlers).
		const target = e.target as HTMLElement;
		if (target.closest('button')) return;
		dragging = true;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		// Offset = pointer minus the dragged surface's current top-left: the
		// floating window while expanded, the bar while collapsed.
		dragOffset = { x: e.clientX - geometry.x, y: e.clientY - geometry.y };
	}

	function onDragMove(e: PointerEvent) {
		if (!dragging) return;
		const nx = e.clientX - dragOffset.x;
		const ny = e.clientY - dragOffset.y;
		// Clamp to keep the dragged surface within the viewport.
		const win = typeof window !== 'undefined' ? window : null;
		if (!win) return;
		if (collapsed) {
			// The bar moves as a whole strip: any position on screen, same
			// 40 px height. It is no longer pinned to the bottom edge.
			const width = Math.min(barWidth ?? winWidth, win.innerWidth);
			barPos = {
				x: Math.max(0, Math.min(win.innerWidth - width, nx)),
				y: Math.max(0, Math.min(win.innerHeight - HEADER_HEIGHT, ny))
			};
			return;
		}
		const clampedX = Math.max(0, Math.min(win.innerWidth - winWidth, nx));
		const clampedY = Math.max(HEADER_HEIGHT, Math.min(win.innerHeight - HEADER_HEIGHT, ny));
		pos = { x: clampedX, y: clampedY };
	}

	function onDragEnd(e: PointerEvent) {
		if (!dragging) return;
		dragging = false;
		(e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
	}

	// ── Edge / corner resize (top / left / top-left corner) ────────────────
	//
	// The window docks bottom-right, so the grippable edges are the ones not
	// flush with the viewport: the TOP edge, the LEFT edge, and the TOP-LEFT
	// corner. Resizing keeps the BOTTOM-RIGHT corner anchored: as the user
	// drags a top/left handle, both `pos` (top-left) and the size move together
	// so the opposite corner stays put. Disabled while maximized (pinned);
	// while collapsed the bar resizes through its own width handle below.
	// Each handle captures the pointer so the drag survives even if the
	// cursor leaves the handle element.
	type ResizeEdge = 'left' | 'top' | 'corner';
	let resizeEdge = $state<ResizeEdge | null>(null);
	/** Fixed bottom-right anchor captured at resize start (viewport coords). */
	let resizeAnchor = $state({ x: 0, y: 0 });

	function onResizeStart(e: PointerEvent, edge: ResizeEdge) {
		if (maximized || collapsed) return;
		const winEl = (e.currentTarget as HTMLElement).closest(
			'.assistant-window'
		) as HTMLElement | null;
		if (!winEl) return;
		const rect = winEl.getBoundingClientRect();
		// Bottom-right corner stays fixed for the whole drag.
		resizeAnchor = { x: rect.right, y: rect.bottom };
		resizeEdge = edge;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		e.stopPropagation();
	}

	function onResizeMove(e: PointerEvent) {
		if (!resizeEdge) return;
		// Desired new top-left = pointer position, clamped so the window never
		// inverts (top-left must stay left of / above the anchor) and never
		// exceeds the viewport max size.
		let nx =
			resizeAnchor.x - Math.max(WIN_WIDTH_MIN, Math.min(MAX_WIDTH, resizeAnchor.x - e.clientX));
		let ny =
			resizeAnchor.y - Math.max(WIN_HEIGHT_MIN, Math.min(MAX_HEIGHT, resizeAnchor.y - e.clientY));
		// Left edge: clamp x; top edge: clamp y; corner: both.
		if (resizeEdge === 'left' || resizeEdge === 'corner') {
			// Keep within the viewport: top-left can't go negative.
			nx = Math.max(0, nx);
		}
		if (resizeEdge === 'top' || resizeEdge === 'corner') {
			// Keep the header reachable: top can't go above the viewport origin.
			ny = Math.max(0, ny);
		}
		// Recompute size from the (clamped) top-left vs the fixed anchor so the
		// bottom-right corner truly stays pinned even after clamping.
		const nextWidth = Math.max(WIN_WIDTH_MIN, Math.min(MAX_WIDTH, resizeAnchor.x - nx));
		const nextHeight = Math.max(WIN_HEIGHT_MIN, Math.min(MAX_HEIGHT, resizeAnchor.y - ny));
		if (resizeEdge === 'left' || resizeEdge === 'corner') {
			pos = { ...pos, x: nx };
			winWidth = nextWidth;
		}
		if (resizeEdge === 'top' || resizeEdge === 'corner') {
			pos = { ...pos, y: ny };
			winHeight = nextHeight;
		}
	}

	function onResizeEnd(e: PointerEvent) {
		if (!resizeEdge) return;
		resizeEdge = null;
		(e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
	}

	// ── Collapsed-bar width resize ──────────────────────────────────────
	//
	// The bar resizes from its LEFT edge; the right edge stays put. The
	// handle renders only while collapsed — the expanded window uses the
	// edge/corner handles above. A resize persists the width and the bar
	// position, so the bar reopens at the size the user set.
	let barResizing = $state(false);
	/** Fixed right-edge anchor captured at bar resize start (viewport x). */
	let barResizeAnchor = $state(0);

	function onBarResizeStart(e: PointerEvent) {
		if (!collapsed) return;
		// Materialize an unset bar position first, so the anchor math below
		// works on real coordinates and the resize persists a full position.
		if (barPos.x < 0) barPos = { x: geometry.x, y: geometry.y };
		barResizeAnchor = barPos.x + (barWidth ?? winWidth);
		barResizing = true;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		e.stopPropagation();
	}

	function onBarResizeMove(e: PointerEvent) {
		if (!barResizing) return;
		const win = typeof window !== 'undefined' ? window : null;
		if (!win) return;
		// Desired width = distance from the pointer to the fixed right edge.
		const desired = barResizeAnchor - e.clientX;
		// Clamp: never below the minimum, never past the viewport's left
		// edge, so the bar never inverts and its x stays on-screen.
		const nextWidth = Math.max(BAR_WIDTH_MIN, Math.min(desired, barResizeAnchor));
		barWidth = nextWidth;
		barPos = { ...barPos, x: barResizeAnchor - nextWidth };
	}

	function onBarResizeEnd(e: PointerEvent) {
		if (!barResizing) return;
		barResizing = false;
		(e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
	}

	// Keep the window inside the viewport on resize so it never gets lost
	// off-screen if the user resizes their browser smaller. (Maximized geometry
	// is recomputed reactively via `geometry` and needs no clamping here.)
	$effect(() => {
		const handler = () => {
			if (typeof window === 'undefined' || pos.x < 0 || maximized) return;
			const clampedX = Math.max(0, Math.min(window.innerWidth - winWidth, pos.x));
			const clampedY = Math.max(HEADER_HEIGHT, Math.min(window.innerHeight - HEADER_HEIGHT, pos.y));
			if (clampedX !== pos.x || clampedY !== pos.y) pos = { x: clampedX, y: clampedY };
		};
		window.addEventListener('resize', handler);
		return () => window.removeEventListener('resize', handler);
	});
</script>

<div
	class="assistant-window"
	class:collapsed
	class:dragging
	class:maximized
	class:resize-dragging={!!resizeEdge || barResizing}
	style:left="{geometry.x}px"
	style:top="{geometry.y}px"
	style:width="{geometry.width}px"
	style:height="{geometry.height}px"
	role="dialog"
	aria-label={m.assistant_title()}
	tabindex="-1"
	onkeydown={onWindowKeydown}
>
	<div
		class="window-header"
		role="toolbar"
		tabindex="-1"
		aria-label={m.assistant_window_controls_aria()}
		onpointerdown={onDragStart}
		onpointermove={onDragMove}
		onpointerup={onDragEnd}
		onpointercancel={onDragEnd}
	>
		<span class="title">
			<Bot size={14} stroke-width={1.9} />
			<span>{title}</span>
		</span>
		{#if badge}
			<span class="badge" title={badge}>{badge}</span>
		{/if}
		<div class="header-actions">
			<button
				class="icon-btn"
				type="button"
				onclick={toggleMaximize}
				aria-label={maximized ? m.assistant_restore_aria() : m.assistant_maximize_aria()}
				aria-pressed={maximized}
				title={maximized ? m.assistant_restore() : m.assistant_maximize()}
			>
				{#if maximized}
					<Minimize2 size={14} stroke-width={1.9} />
				{:else}
					<Maximize2 size={14} stroke-width={1.9} />
				{/if}
			</button>
			<button
				class="icon-btn"
				type="button"
				onclick={toggleCollapse}
				aria-label={collapsed ? m.assistant_expand_aria() : m.assistant_collapse_aria()}
				aria-pressed={!collapsed}
				title={collapsed ? m.assistant_expand() : m.assistant_collapse()}
			>
				<Minus size={14} stroke-width={1.9} />
			</button>
			{#if onclose}
				<button
					class="icon-btn"
					type="button"
					onclick={onclose}
					aria-label={m.assistant_close_aria()}
					title={m.common_close()}
				>
					<X size={14} stroke-width={1.9} />
				</button>
			{/if}
		</div>
	</div>

	<!-- Keep the body mounted while collapsed — CSS hides it (display:none).
	     An unmount here would drop the hosted panel's state: the selected
	     conversation, the loaded turns, the composer text, and a live stream. -->
	<!-- The window mounts at the root layout, outside the page-level boundary,
	     and renders model-generated content (preview cards, document cards) —
	     a crash here must degrade to the fallback card inside the window, not
	     take the whole app down through the app-level boundary. Closing and
	     reopening the window remounts a fresh boundary. -->
	<div class="window-body" class:body-hidden={collapsed}>
		<ErrorBoundary>{@render children?.()}</ErrorBoundary>
	</div>

	<!-- Edge / corner resize handles (top / left / top-left corner). The
     window docks bottom-right, so these are the edges not flush with the
     viewport. Hidden while maximized or collapsed so they never intercept
     the maximized window or the bar — the bar has its own width handle
     below. -->
	{#if !maximized && !collapsed}
		<div
			class="resize-handle resize-left"
			role="separator"
			aria-orientation="vertical"
			aria-label={m.assistant_resize_width_aria()}
			onpointerdown={(e) => onResizeStart(e, 'left')}
			onpointermove={onResizeMove}
			onpointerup={onResizeEnd}
			onpointercancel={onResizeEnd}
		></div>
		<div
			class="resize-handle resize-top"
			role="separator"
			aria-orientation="horizontal"
			aria-label={m.assistant_resize_height_aria()}
			onpointerdown={(e) => onResizeStart(e, 'top')}
			onpointermove={onResizeMove}
			onpointerup={onResizeEnd}
			onpointercancel={onResizeEnd}
		></div>
		<div
			class="resize-handle resize-corner"
			role="separator"
			aria-label={m.assistant_resize_aria()}
			onpointerdown={(e) => onResizeStart(e, 'corner')}
			onpointermove={onResizeMove}
			onpointerup={onResizeEnd}
			onpointercancel={onResizeEnd}
		></div>
	{/if}

	<!-- Collapsed-bar width handle. The bar resizes from its left edge; the
     right edge stays put. Hidden while expanded — the edge/corner handles
     above own resizing then. -->
	{#if collapsed}
		<div
			class="resize-handle resize-left"
			role="separator"
			aria-orientation="vertical"
			aria-label={m.assistant_resize_width_aria()}
			onpointerdown={onBarResizeStart}
			onpointermove={onBarResizeMove}
			onpointerup={onBarResizeEnd}
			onpointercancel={onBarResizeEnd}
		></div>
	{/if}
</div>

<style>
	.assistant-window {
		position: fixed;
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		box-shadow:
			0 10px 30px rgba(0, 0, 0, 0.18),
			0 2px 8px rgba(0, 0, 0, 0.08);
		overflow: hidden;
		z-index: 1000;
		/* Animate geometry (maximize/restore, collapse) but disable during drag. */
		transition:
			left 0.18s ease,
			top 0.18s ease,
			width 0.18s ease,
			height 0.18s ease;
	}

	.assistant-window.dragging,
	.assistant-window.resize-dragging {
		transition: none;
	}

	/* Prevent text selection while resizing the window edges/corner. */
	.assistant-window.resize-dragging {
		user-select: none;
	}

	.assistant-window.collapsed {
		border-radius: var(--r-sm) var(--r-sm) var(--r) var(--r);
	}

	/* Flex parent for the children snippet (the ChatPanel fills it with
	   flex:1). While collapsed it is display:none only — the children stay
	   mounted, so the hosted surface keeps its state (see the template
	   note). */
	.window-body {
		flex: 1;
		display: flex;
		flex-direction: column;
		min-height: 0;
		min-width: 0;
	}

	.window-body.body-hidden {
		display: none;
	}

	.assistant-window.maximized .window-header {
		cursor: default;
	}

	.window-header {
		display: flex;
		align-items: center;
		gap: 8px;
		height: 40px;
		padding: 0 10px;
		border-bottom: 1px solid var(--border);
		background: var(--surface-2, var(--surface));
		cursor: grab;
		user-select: none;
		flex-shrink: 0;
		touch-action: none;
	}

	.assistant-window.collapsed .window-header {
		border-bottom: none;
	}

	.window-header:active {
		cursor: grabbing;
	}

	.title {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font-family: var(--font-display);
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
	}

	.badge {
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
		background: var(--sunken);
		padding: 2px 7px;
		border-radius: var(--r-sm);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		max-width: 120px;
	}

	.header-actions {
		display: inline-flex;
		align-items: center;
		position: relative;
		z-index: 5;
		gap: 2px;
		margin-left: auto;
	}

	.icon-btn {
		display: grid;
		place-items: center;
		width: 28px;
		height: 28px;
		border: none;
		border-radius: var(--r-sm);
		background: transparent;
		color: var(--text-3);
		cursor: pointer;
		transition:
			background 0.12s ease,
			color 0.12s ease;
	}

	.icon-btn:hover {
		background: var(--sunken);
		color: var(--text);
	}

	/* ── Edge / corner resize handles ─────────────────────────────────── */
	.resize-handle {
		position: absolute;
		z-index: 3;
		background: transparent;
		transition: background 0.12s ease;
	}
	.resize-handle:hover,
	.resize-handle:active {
		background: var(--accent-weak);
	}
	.resize-handle:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: -2px;
	}

	.resize-left {
		top: 0;
		left: 0;
		width: 6px;
		height: 100%;
		cursor: col-resize;
	}
	.resize-top {
		top: 0;
		left: 0;
		width: 100%;
		height: 6px;
		cursor: row-resize;
	}
	.resize-corner {
		top: 0;
		left: 0;
		width: 14px;
		height: 14px;
		cursor: nwse-resize;
		z-index: 4;
	}
</style>

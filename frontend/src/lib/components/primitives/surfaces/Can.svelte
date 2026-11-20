<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { can, canScope } from '$lib/permissions.svelte';

	let {
		doctype,
		action,
		/**
		 * Optional scope gate. When `'unrestricted'`, the block renders only if the
		 * action is granted AND has no scope restriction (Lua `ctx.actor.scope == nil`).
		 * Useful for affordances like creating a *general* (shared) resource, which
		 * requires an unrestricted permission line — a `$mine`-scoped `create` is
		 * not enough. Omit to check action presence only (the legacy behaviour).
		 */
		scope,
		children,
		fallback
	}: {
		/** Qualified doctype key, e.g. `"core.DocType"`. */
		doctype: string;
		/** Action name: `read`, `create`, `update`, `delete`, `*`, or a custom action (e.g. `promote`). */
		action: string;
		scope?: 'unrestricted';
		/** Rendered when the active role holds `action` on `doctype`. */
		children?: import('svelte').Snippet;
		/** Rendered when the check fails. Omit to render nothing. */
		fallback?: import('svelte').Snippet;
	} = $props();

	const allowed = $derived(
		can(doctype, action) &&
			(scope === 'unrestricted' ? canScope(doctype, action) === 'unrestricted' : true)
	);
</script>

{#if allowed}
	{@render children?.()}
{:else}
	{@render fallback?.()}
{/if}

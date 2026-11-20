<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ErrorBoundary from './ErrorBoundary.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/ErrorBoundary',
		component: ErrorBoundary,
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	// @ts-expect-error — the addon ships no types for its $app/state mock
	import { setAppStatePage } from '@storybook/sveltekit/internal/mocks/app/state.svelte.js';
	import * as m from '$lib/paraglide/messages';

	// Test double: throws during render when the story calls it.
	function boom(): string {
		throw new Error('render exploded (test double)');
	}

	// Test double: throws Svelte's hydration-failure sentinel — a bare `{}`.
	// The real one (`HYDRATION_ERROR` in svelte's internals) has no message
	// and no own properties, so this is structurally identical.
	function sentinelBoom(): string {
		throw {};
	}

	// Session-local toggle, shared by the play below (see ConfirmDialog.stories
	// for the same pattern; args mutations are invisible to play functions).
	let broken = $state(false);
	let sentinelArmed = $state(false);

	const healthyLabel = 'Page content renders normally.';
</script>

<!--
	The play toggles a render-time throw inside the boundary and walks both
	recovery paths: Retry (remount) and a simulated navigation (the boundary
	must drop the fallback when the URL changes).
-->
<Story
	name="RecoversFromRenderError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		broken = false;
		setAppStatePage({ url: new URL(location.origin) });

		// Healthy first paint.
		await expect(canvas.getByText(healthyLabel)).toBeVisible();

		// Break the child; the boundary must catch and show the fallback.
		broken = true;
		await waitFor(() => expect(canvas.getByText(m.errors_500_title())).toBeVisible());
		await expect(canvas.queryByText(healthyLabel)).toBeNull();

		// Recovery path 1 — Retry remounts the boundary; the child is healthy
		// again because the toggle is back to false.
		broken = false;
		await userEvent.click(canvas.getByRole('button', { name: m.common_retry() }));
		await waitFor(() => expect(canvas.getByText(healthyLabel)).toBeVisible());
		await expect(canvas.queryByText(m.errors_500_title())).toBeNull();

		// Recovery path 2 — a navigation drops the fallback on its own. The
		// mock's URL write flushes in a microtask, so the assertions poll.
		broken = true;
		await waitFor(() => expect(canvas.getByText(m.errors_500_title())).toBeVisible());
		broken = false;
		setAppStatePage({ url: new URL(`${location.origin}/another-page`) });
		await waitFor(() => expect(canvas.getByText(healthyLabel)).toBeVisible());
		await expect(canvas.queryByText(m.errors_500_title())).toBeNull();

		// Leave the shared $app/state mock as this story found it.
		setAppStatePage({ url: new URL(location.origin) });
	}}
>
	{#snippet template(_args)}
		<div style="padding: 24px; min-height: 300px;">
			<button onclick={() => (broken = !broken)}>Toggle broken</button>
			<ErrorBoundary>
				{#if broken}
					<p>{boom()}</p>
				{:else}
					<p>{healthyLabel}</p>
				{/if}
			</ErrorBoundary>
		</div>
	{/snippet}
</Story>

<!--
	The hydration-sentinel path: Svelte's internal hydration-failure error is
	a bare `{}` (HYDRATION_ERROR — module-private, unimportable). A browser
	extension that injects a node into the SSR HTML before hydration finishes
	(LastPass decorating a credential form) surfaces exactly this error. The
	boundary must re-render the content client-side instead of showing the
	fallback. The child throws the sentinel only on its first render — the
	recovery is one-shot per boundary instance, mirroring the real failure:
	hydration runs once, and a client render cannot trip it again.
-->
<Story
	name="RecoversFromHydrationSentinel"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		sentinelArmed = true;

		// The child throws the bare-object sentinel on the first render; the
		// boundary must recover with a client render, no fallback card.
		await waitFor(() => expect(canvas.getByText(healthyLabel)).toBeVisible());
		await expect(canvas.queryByText(m.errors_500_title())).toBeNull();

		sentinelArmed = false;
	}}
>
	{#snippet template(_args)}
		<div style="padding: 24px; min-height: 300px;">
			<ErrorBoundary>
				{#if sentinelArmed}
					<p>{sentinelBoom()}</p>
				{:else}
					<p>{healthyLabel}</p>
				{/if}
			</ErrorBoundary>
		</div>
	{/snippet}
</Story>

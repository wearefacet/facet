<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import WelcomeArtIntegrate from './WelcomeArtIntegrate.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Welcome/WelcomeArtIntegrate',
		component: WelcomeArtIntegrate,
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	import { expect, within } from 'storybook/test';
</script>

<!--
	The art renders on the dialog surface in the tour, so each story mounts
	it on `--surface` inside a fixed-width column that matches the tour card.
	The play asserts the accessible name that comes from the
	`welcome_integrate_art_aria` message. The dark story shows the
	token-driven palette on the dark surface.
-->

<Story
	name="Integrate"
	play={async () => {
		const body = within(document.body);
		const art = body.getByRole('img', {
			name: 'Lua hooks triggered by changes or a schedule feed Facet; REST API, API keys, OAuth and MCP connect it to your stack; data stays in PostgreSQL; a domain is exported as a bundle'
		});
		await expect(art).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="display: flex; justify-content: center; padding: 24px; background: var(--surface);">
			<div style="width: 400px;">
				<WelcomeArtIntegrate />
			</div>
		</div>
	{/snippet}
</Story>

<Story name="Dark">
	{#snippet template()}
		<div
			class="dark"
			style="display: flex; justify-content: center; padding: 24px; background: var(--ground);"
		>
			<div style="width: 400px;">
				<WelcomeArtIntegrate />
			</div>
		</div>
	{/snippet}
</Story>

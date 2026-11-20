<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import Panel from './Panel.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/Panel',
		component: Panel,
		tags: ['autodocs']
	});
</script>

<Story name="Default">
	<p style="margin:0">
		A generic card container with surface background, border, rounded corners, and shadow.
	</p>
</Story>

<Story
	name="NoPadding"
	args={{
		padding: false
	}}
>
	<div style="padding: 20px 22px">Content controls its own padding.</div>
</Story>

<Story name="Nested">
	<div style="display:flex;flex-direction:column;gap:12px">
		<b>Outer panel</b>
		<div
			style="background:var(--surface-2);border:1px solid var(--border);border-radius:var(--r);padding:12px 14px;font-size:13px;color:var(--text-2)"
		>
			Inner card (no panel)
		</div>
	</div>
</Story>

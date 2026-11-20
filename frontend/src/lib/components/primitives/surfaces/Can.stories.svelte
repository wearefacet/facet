<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import Can from './Can.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/Can',
		component: Can,
		tags: ['autodocs']
	});
</script>

<!--
	`<Can>` is renderless — it only forwards `children`/`fallback`.
	Each story wraps the demo in `<CanFixture manifest={...}>`, which sets
	the permission store synchronously during initialization (before `<Can>`
	reads it), so each story has a clean, isolated manifest.
-->

<Story name="Allowed">
	{#snippet template()}
		<CanFixture manifest={{ 'core.DocType': ['update'] }}>
			<button>configure</button>
		</CanFixture>
	{/snippet}
</Story>

<Story name="Denied">
	{#snippet template()}
		<CanFixture manifest={{ 'core.DocType': ['read'] }}>
			<Can doctype="core.DocType" action="update">
				<button>configure</button>
			</Can>
			<p style="color:var(--text-3);font-size:13px;margin-top:8px">
				Button hidden — role has `read` only, not `update`.
			</p>
		</CanFixture>
	{/snippet}
</Story>

<Story name="Fallback">
	{#snippet template()}
		<CanFixture manifest={{ 'core.DocType': ['read'] }}>
			<Can doctype="core.DocType" action="update">
				<button>configure</button>
				{#snippet fallback()}
					<span style="color:var(--text-3);font-size:13px">No permission to configure</span>
				{/snippet}
			</Can>
		</CanFixture>
	{/snippet}
</Story>

<Story name="AdminWildcard">
	{#snippet template()}
		<CanFixture manifest={{ '*.*': ['*'] }}>
			<Can doctype="core.DocType" action="update">
				<button>configure</button>
			</Can>
		</CanFixture>
	{/snippet}
</Story>

<Story name="CustomAction">
	{#snippet template()}
		<CanFixture manifest={{ 'crm.Deal': ['win'] }}>
			<Can doctype="crm.Deal" action="win">
				<button>mark as won</button>
			</Can>
		</CanFixture>
	{/snippet}
</Story>

<Story name="NoManifest">
	{#snippet template()}
		<CanFixture manifest={null}>
			<Can doctype="core.DocType" action="update">
				<button>configure</button>
			</Can>
			<p style="color:var(--text-3);font-size:13px;margin-top:8px">
				Fail-closed: no manifest loaded, children never render.
			</p>
		</CanFixture>
	{/snippet}
</Story>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import TabPane from './TabPane.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Navigation/TabPane',
		component: TabPane,
		tags: ['autodocs']
	});
</script>

<Story
	name="Active"
	args={{
		active: true
	}}
>
	<div style="padding: 16px; color: var(--text-2);">
		This tab pane is <strong>active</strong> — content is visible.
	</div>
</Story>

<Story
	name="Inactive"
	args={{
		active: false
	}}
>
	<div style="padding: 16px; color: var(--text-2);">
		This tab pane is <strong>inactive</strong> — content is hidden.
	</div>
</Story>

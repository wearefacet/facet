<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import CopyCapsule from './CopyCapsule.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/CopyCapsule',
		component: CopyCapsule,
		tags: ['autodocs']
	});
</script>

<Story name="Default" args={{ value: 'alice@example.com' }} />

<Story name="WithCustomLabel" args={{ value: 'alice@example.com', label: 'alice (work)' }} />

<Story name="PhoneLike" args={{ value: '+1 (555) 010-1234 ext. 42' }} />

<!-- Constrained width to demonstrate CSS ellipsis truncation -->
<Story name="Constrained">
	<div style="width: 180px">
		<CopyCapsule value="very.long.value.that.should.truncate@somewhere.example.com" />
	</div>
</Story>

<Story
	name="CopiesOnClick"
	args={{ value: 'copy-me@example.com' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const btn = canvas.getByRole('button');
		await expect(btn).toHaveAccessibleName('Copy copy-me@example.com');
		await expect(btn).toHaveTextContent('copy-me@example.com');
	}}
/>

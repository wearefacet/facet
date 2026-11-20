<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect } from 'storybook/test';
	import DoctypeIcon from './DoctypeIcon.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/DoctypeIcon',
		component: DoctypeIcon,
		tags: ['autodocs']
	});
</script>

<Story
	name="FallbackDiamond"
	args={{ icon: '', color: '#c89329' }}
	play={async ({ canvasElement }) => {
		// No icon configured → the signature diamond renders.
		await expect(canvasElement.querySelector('.doctype-icon-diamond')).not.toBeNull();
		await expect(canvasElement.querySelector('.doctype-icon-glyph')).toBeNull();
	}}
/>

<Story
	name="UnknownIconFallsBackToDiamond"
	args={{ icon: 'this-icon-does-not-exist', color: '#5B8DEF' }}
	play={async ({ canvasElement }) => {
		await expect(canvasElement.querySelector('.doctype-icon-diamond')).not.toBeNull();
	}}
/>

<Story
	name="ConfiguredIcon"
	args={{ icon: 'building-2', color: '#5B8DEF', size: 16 }}
	play={async ({ canvasElement }) => {
		await expect(canvasElement.querySelector('.doctype-icon-glyph')).not.toBeNull();
		await expect(canvasElement.querySelector('.doctype-icon-diamond')).toBeNull();
		// The glyph renders an inline SVG.
		await expect(canvasElement.querySelector('.doctype-icon-glyph svg')).not.toBeNull();
	}}
/>

<Story name="ShadowDiamond" args={{ icon: '', color: '#B05E2E', shadow: true }} />

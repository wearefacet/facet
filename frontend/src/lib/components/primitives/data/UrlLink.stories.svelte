<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import UrlLink from './UrlLink.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/UrlLink',
		component: UrlLink,
		tags: ['autodocs']
	});
</script>

<Story name="Default" args={{ href: 'https://example.com' }} />

<Story name="WithCustomLabel" args={{ href: 'https://acme.com', label: 'Acme website' }} />

<Story
	name="LongUrl"
	args={{ href: 'https://example.com/very/long/path/with/many/segments?tab=profile' }}
/>

<!-- Constrained width to demonstrate CSS ellipsis truncation -->
<Story name="Constrained">
	<div style="width: 180px">
		<UrlLink href="https://example.com/very/long/path/with/many/segments?tab=profile" />
	</div>
</Story>

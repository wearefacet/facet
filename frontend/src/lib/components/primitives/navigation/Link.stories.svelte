<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import Link from './Link.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Navigation/Link',
		component: Link,
		tags: ['autodocs']
	});
</script>

<Story name="Default" args={{ label: 'View details', href: '#' }} />
<Story name="External" args={{ label: 'Open in new tab', href: 'https://example.com' }} />

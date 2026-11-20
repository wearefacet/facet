<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import Tag from './Tag.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/Tag',
		component: Tag,
		tags: ['autodocs']
	});
</script>

<Story name="Default" args={{ label: 'urgent' }} />
<Story name="Long" args={{ label: 'needs-approval' }} />

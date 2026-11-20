<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import Chip from './Chip.svelte';
	import { Flag } from '@lucide/svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/Chip',
		component: Chip,
		tags: ['autodocs'],
		argTypes: {
			variant: {
				control: 'select',
				options: ['default', 'active']
			}
		},
		args: {
			onclose: fn()
		}
	});
</script>

{#snippet iconFlag()}
	<Flag size={12} />
{/snippet}

<Story name="Default" args={{ label: 'Draft' }} />
<Story name="Active" args={{ label: 'Reconciled', variant: 'active' }} />
<Story name="Closable" args={{ label: 'Filter: Paid', closable: true }} />
<Story
	name="ActiveClosable"
	args={{ label: 'Status: Active', variant: 'active', closable: true }}
/>

<Story name="WithIcon" args={{ variant: 'active', label: 'Flagged', children: iconFlag }} />

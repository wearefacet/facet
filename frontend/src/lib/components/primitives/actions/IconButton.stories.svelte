<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import IconButton from './IconButton.svelte';
	import { Bell, Cog, X } from '@lucide/svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Actions/IconButton',
		component: IconButton,
		tags: ['autodocs'],
		args: {
			onclick: fn()
		}
	});
</script>

{#snippet iconBell()}
	<Bell size={16} />
{/snippet}

{#snippet iconCog()}
	<Cog size={16} />
{/snippet}

{#snippet iconX()}
	<X size={16} />
{/snippet}

<Story name="Bell" args={{ label: 'Notifications', children: iconBell }} />
<Story name="Settings" args={{ label: 'Settings', children: iconCog }} />
<Story name="Close" args={{ label: 'Close', children: iconX }} />
<Story name="Disabled" args={{ label: 'Notifications', disabled: true, children: iconBell }} />

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import Avatar from './Avatar.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Content/Avatar',
		component: Avatar,
		tags: ['autodocs'],
		argTypes: {
			size: {
				control: 'select',
				options: ['sm', 'md', 'lg']
			}
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story name="Initials" args={{ initials: 'YA' }} />
<Story name="WithBackground" args={{ initials: 'SM', background: 'var(--dt-contact)' }} />
<Story name="Small" args={{ initials: 'YA', size: 'sm' }} />
<Story name="Large" args={{ initials: 'YA', size: 'lg' }} />

<Story
	name="Image"
	args={{
		src: 'https://i.pravatar.cc/40?img=3',
		alt: 'User avatar',
		initials: 'JD'
	}}
/>

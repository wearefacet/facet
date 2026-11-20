<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import EmailCapsule from './EmailCapsule.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/EmailCapsule',
		component: EmailCapsule,
		tags: ['autodocs']
	});
</script>

<Story name="Default" args={{ email: 'alice@example.com' }} />

<Story name="WithCustomLabel" args={{ email: 'bob@example.com', label: 'bob (personal)' }} />

<Story name="LongEmail" args={{ email: 'very.long.email.address@subdomain.example.com' }} />

<!-- Constrained width to demonstrate CSS ellipsis truncation -->
<Story name="Constrained">
	<div style="width: 180px">
		<EmailCapsule email="alice.johnson.middle.initial@verylongdomain.example.com" />
	</div>
</Story>

<Story
	name="VeryLongDomain"
	args={{ email: 'hello@this-is-a-very-long-domain-name-that-should-truncate.example.com' }}
/>

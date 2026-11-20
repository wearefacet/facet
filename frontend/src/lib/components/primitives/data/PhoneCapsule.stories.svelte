<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import PhoneCapsule from './PhoneCapsule.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/PhoneCapsule',
		component: PhoneCapsule,
		tags: ['autodocs']
	});
</script>

<Story name="Default" args={{ phone: '+1-555-0100' }} />

<Story name="WithCustomLabel" args={{ phone: '+44 7700 900123', label: 'mobile (Amara)' }} />

<Story name="LongNumber" args={{ phone: '+1 (555) 010-1234 ext. 42' }} />

<!-- Constrained width to demonstrate CSS ellipsis truncation -->
<Story name="Constrained">
	<div style="width: 180px">
		<PhoneCapsule phone="+1 (555) 010-1234 ext. 42" />
	</div>
</Story>

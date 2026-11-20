<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DomainSchematic from './DomainSchematic.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';

	const driver = createMockDriver();

	const { Story } = defineMeta({
		title: 'Components/Schematic/DomainSchematic',
		component: DomainSchematic,
		tags: ['autodocs'],
		argTypes: {
			domain: {
				control: 'select',
				options: ['hr', 'crm', 'core', 'iam', 'identity']
			}
		},
		args: {
			registry: driver
		}
	});
</script>

<Story name="HRDomain" args={{ domain: 'hr' }} />

<Story name="CRMDomain" args={{ domain: 'crm' }} />

<Story name="CoreDomain" args={{ domain: 'core' }} />

<Story name="IAMDomain" args={{ domain: 'iam' }} />

<Story name="IdentityDomain" args={{ domain: 'identity' }} />

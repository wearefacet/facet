<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ToolCallBar from './ToolCallBar.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ToolCallBar',
		component: ToolCallBar,
		tags: ['autodocs'],
		argTypes: {
			status: {
				control: 'select',
				options: ['running', 'ok', 'error']
			}
		}
	});
</script>

<Story
	name="Ok"
	args={{
		name: 'inspect_domain',
		detail: 'inspected domain crm — found Customer, Contact, Deal',
		result: '6 doctypes',
		status: 'ok'
	}}
/>

<Story
	name="Running"
	args={{
		name: 'search_doctypes',
		detail: 'querying projections for "shipment"',
		status: 'running'
	}}
/>

<Story
	name="Error"
	args={{
		name: 'apply_mutation',
		detail: 'create doctype logistics.Shipment',
		result: 'validation failed',
		status: 'error'
	}}
/>

<Story
	name="Minimal"
	args={{
		name: 'list_domains',
		status: 'ok'
	}}
/>

<Story
	name="LongResult"
	args={{
		name: 'inspect_domain',
		detail: 'inspected domain crm',
		status: 'ok',
		result: JSON.stringify(
			{
				domain: 'crm',
				doctypes: [
					{ name: 'Customer', fields: 12 },
					{ name: 'Contact', fields: 8 },
					{ name: 'Deal', fields: 15 }
				]
			},
			null,
			2
		)
	}}
/>

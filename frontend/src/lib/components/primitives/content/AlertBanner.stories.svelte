<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import AlertBanner from './AlertBanner.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Content/AlertBanner',
		component: AlertBanner,
		tags: ['autodocs'],
		argTypes: {
			variant: {
				control: 'select',
				options: ['danger', 'warn']
			}
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="Danger"
	args={{ message: 'Create failed: required field "email" is missing' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(
			canvas.getByText('Create failed: required field "email" is missing')
		).toBeVisible();
	}}
/>

<Story name="Warn" args={{ message: 'This domain has unresolved references', variant: 'warn' }} />

<Story
	name="WithDetails"
	args={{
		message: 'Save failed',
		details: ['Script error: division by zero', 'RBAC: missing create grant on crm.Deal']
	}}
/>

<Story
	name="Dismissable"
	args={{ message: 'Network error — could not create draft', dismissable: true }}
/>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import RoleMemberRow from './RoleMemberRow.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Admin/RoleMemberRow',
		component: RoleMemberRow,
		tags: ['autodocs'],
		args: {
			onremove: fn()
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="AccountRow"
	args={{
		title: 'Ada Lovelace',
		email: 'ada@acme.dev',
		metaId: '01J8ZQ4M9K2X7V3B5N8P1C6D9F',
		status: 'active',
		isDefault: true
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Ada Lovelace')).toBeVisible();
		await expect(canvas.getByText('active')).toBeVisible();
		await expect(canvas.getByText('default')).toBeVisible();
	}}
/>

<Story
	name="SuspendedAccount"
	args={{
		title: 'grace@acme.dev',
		email: 'grace@acme.dev',
		metaId: '01J8ZQ4M9K2X7V3B5N8P1C6D9G',
		status: 'suspended'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('suspended')).toBeVisible();
	}}
/>

<Story
	name="RoleRow"
	args={{
		title: 'Production Editor',
		description: 'Edits published documents in the crm domain.'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Production Editor')).toBeVisible();
		await expect(canvas.getByText('Edits published documents in the crm domain.')).toBeVisible();
	}}
/>

<Story name="RoleRowUnknownId" args={{ title: 'Unknown role', metaId: 'iam.Roles.gone' }} />

<Story
	name="Removing"
	args={{ title: 'Busy row', email: 'busy@acme.dev', metaId: '01JBUSY', removing: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Removing…')).toBeVisible();
	}}
/>

<Story
	name="RemoveClick"
	args={{ title: 'Clickable', email: 'c@acme.dev', metaId: '01JCLK' }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const btn = canvas.getByRole('button', { name: 'Remove' });
		await userEvent.click(btn);
		await expect(args.onremove).toHaveBeenCalledOnce();
	}}
/>

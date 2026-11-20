<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import RoleAssignmentEditor from './RoleAssignmentEditor.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Admin/RoleAssignmentEditor',
		component: RoleAssignmentEditor,
		tags: ['autodocs'],
		// A11y backlog: the subject pickers and the add pickers carry a
		// placeholder only (no accessible name). The markup is carried over
		// from the assignments page and kept identical by the refactor
		// contract. Give the pickers labels, then remove this override.
		parameters: { a11y: { test: 'todo' } },
		args: {
			onnavigate: fn(),
			onrefresh: fn()
		}
	});
</script>

<script lang="ts">
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { expect, within, waitFor, userEvent } from 'storybook/test';
	import RoleAssignmentEditorInner from './RoleAssignmentEditor.svelte';

	// A fresh driver per story-file mount — keeps stories isolated (same
	// pattern as RbacEditor.stories). The mock seeds do carry `iam.Account`
	// rows (Kim holds `iam.Roles.admin`; Dao, Sam and Alex hold
	// `iam.Roles.editor`), so a role-mode story must pick a role no seed
	// account holds to see a single-member list — Ada gets the unheld
	// `iam.Roles.production_editor`. Bob gets `iam.Roles.viewer` for the
	// account-mode story. `create` assigns opaque ids — capture the id the
	// account-mode story needs.
	const driver = createMockDriver();

	let ready = $state(false);
	let bobId = $state('');

	(async () => {
		const accounts = driver.domain('iam').doctype('Account');
		await accounts.create({
			email: 'ada@example.com',
			name: 'Ada Lovelace',
			status: 'active',
			roles: ['iam.Roles.production_editor'],
			default_role: 'iam.Roles.production_editor'
		});
		const bob = await accounts.create({
			email: 'bob@example.com',
			name: 'Bob Example',
			status: 'suspended',
			roles: ['iam.Roles.viewer']
		});
		bobId = bob.meta.id;
		ready = true;
	})();
</script>

<Story
	name="RoleModeNoRolePicked"
	args={{ selectedRole: '' }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// No role picked: the hint shows, the member list does not render,
		// and no load error appears.
		await canvas.findByText('Pick a role above to see its members.');
		await expect(canvas.getByText('Members of role')).toBeVisible();
		await expect(canvas.queryByText('Loading members…')).not.toBeInTheDocument();
		// The mode toggle asks the host to update the URL state.
		await userEvent.click(canvas.getByRole('tab', { name: 'By account' }));
		await expect(args.onnavigate).toHaveBeenCalledWith({ mode: 'account' });
	}}
>
	{#snippet template(args)}
		{#if ready}
			<div style="min-height: 400px; padding: 24px">
				<RoleAssignmentEditorInner
					{driver}
					mode="role"
					selectedRole={args.selectedRole}
					onnavigate={args.onnavigate}
					onrefresh={args.onrefresh}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<Story
	name="RoleModeMembersRemove"
	args={{ selectedRole: 'iam.Roles.production_editor' }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The role chip labels the picked role; the member list shows only
		// the accounts that hold it. No seed account holds production_editor,
		// so Ada is the single member (Bob holds viewer anyway). The email
		// sits in a mixed-content sub-line, so assert the display name.
		await canvas.findByText('Ada Lovelace');
		await expect(canvas.getByText('Production Editor')).toBeVisible();
		await expect(canvas.queryByText('Bob Example')).toBeNull();
		await expect(canvas.queryByText('Kim Nguyen')).toBeNull();
		// No add-picker selection yet: the add action stays disabled.
		await expect(canvas.getByRole('button', { name: 'Add to role' })).toBeDisabled();
		// Removing the member writes through the injected driver, reloads the
		// list, and signals the host.
		await userEvent.click(canvas.getByRole('button', { name: 'Remove' }));
		await waitFor(() => expect(canvas.getByText('No members yet. Add one above.')).toBeVisible());
		await waitFor(() => expect(args.onrefresh).toHaveBeenCalled());
	}}
>
	{#snippet template(args)}
		{#if ready}
			<div style="min-height: 400px; padding: 24px">
				<RoleAssignmentEditorInner
					{driver}
					mode="role"
					selectedRole={args.selectedRole}
					onnavigate={args.onnavigate}
					onrefresh={args.onrefresh}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<Story
	name="AccountModeRolesRemove"
	args={{ selectedAccount: '' }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The account chip labels the picked account; the list shows the
		// assigned roles with their descriptions.
		await canvas.findByText('Bob Example');
		await canvas.findByText('Viewer');
		await expect(canvas.getByText('Read-only access to all resources.')).toBeVisible();
		// No add-picker selection yet: the assign action stays disabled.
		await expect(canvas.getByRole('button', { name: 'Assign role' })).toBeDisabled();
		// Removing the role writes through the injected driver, reloads the
		// list, and signals the host.
		await userEvent.click(canvas.getByRole('button', { name: 'Remove' }));
		await waitFor(() =>
			expect(canvas.getByText('No roles assigned. Add one above.')).toBeVisible()
		);
		await waitFor(() => expect(args.onrefresh).toHaveBeenCalled());
	}}
>
	{#snippet template(args)}
		{#if ready}
			<div style="min-height: 400px; padding: 24px">
				<RoleAssignmentEditorInner
					{driver}
					mode="account"
					selectedAccount={args.selectedAccount || bobId}
					onnavigate={args.onnavigate}
					onrefresh={args.onrefresh}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

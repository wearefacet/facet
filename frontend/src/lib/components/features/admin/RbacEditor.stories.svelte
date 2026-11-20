<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import RbacEditor from './RbacEditor.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Admin/RbacEditor',
		component: RbacEditor,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { expect, within, waitFor, userEvent } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
	import type { ListItem } from '$lib/datasource/types.js';
	import RbacEditorInner from './RbacEditor.svelte';
	import type { PermissionRaw } from './rbacModel.js';

	// A fresh driver per story mount — keeps stories isolated and avoids
	// importing the singleton from `.storybook/preview.ts` (which lives
	// outside `src/` and is brittle to reach via relative paths).
	const driver = createMockDriver();

	type RoleContent = { name?: string; description?: string };
	type RoleListItem = ListItem<RoleContent>;
	type DomainListItem = { id: string; data: Record<string, unknown> };

	let roles = $state<RoleListItem[]>([]);
	let domains = $state<DomainListItem[]>([]);
	let loaded = $state(false);

	// Captured by the RouteGatedActions story's onsave handler and asserted
	// in its play function — one shared binding for the snippet and the play.
	let savedPermissions = $state<PermissionRaw[]>([]);

	// A synthetic `editor` role carrying the seed file's exact permission
	// lines (data/seeds/iam.Roles/documents.yml) — wildcard lines with their
	// `except` carve-outs plus the domain-scoped lines. The WildcardCarveOutsSurvive
	// story mounts it through the `roles` prop so the assertion is independent
	// of which variant the mock driver serves for the shared `iam.Roles.editor` id.
	const editorPermissions: PermissionRaw[] = [
		{
			action: 'create',
			on: '*.*',
			except: [
				'core.DocType',
				'core.DocumentView',
				'core.DomainEditor',
				'core.SchematicLayout',
				'core.SystemSettings',
				'iam.OIDCProvider'
			]
		},
		{
			action: 'update',
			on: '*.*',
			except: [
				'core.Domain',
				'core.DocType',
				'core.DocumentView',
				'core.DomainEditor',
				'core.SchematicLayout',
				'core.SystemSettings',
				'iam.OIDCProvider',
				'core.Webhook'
			]
		},
		{
			action: 'delete',
			on: '*.*',
			except: [
				'core.Domain',
				'core.DocType',
				'core.DocumentView',
				'core.DomainEditor',
				'core.SchematicLayout',
				'core.SystemSettings',
				'iam.OIDCProvider',
				'core.Webhook'
			]
		},
		{
			action: 'read',
			on: '*.*',
			except: ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook']
		},
		{ action: 'update', on: 'core.Domain', scope: ['$domain_editor'] },
		{ action: 'delete', on: 'core.Domain', scope: ['$domain_editor_draft'] },
		{ action: 'create', on: 'core.DocType', scope: ['$domain_editor'] },
		{ action: 'update', on: 'core.DocType', scope: ['$domain_editor'] },
		{ action: 'delete', on: 'core.DocType', scope: ['$domain_editor'] },
		{ action: 'create', on: 'core.DocumentView', scope: ['$domain_editor'] },
		{ action: 'update', on: 'core.DocumentView', scope: ['$domain_editor'] },
		{ action: 'delete', on: 'core.DocumentView', scope: ['$domain_editor'] },
		{ action: 'create', on: 'core.SchematicLayout', scope: ['$domain_editor'] },
		{ action: 'update', on: 'core.SchematicLayout', scope: ['$domain_editor'] },
		{ action: 'read', on: 'core.Webhook', scope: ['$mine'] },
		{ action: 'update', on: 'core.Webhook', scope: ['$mine'] },
		{ action: 'delete', on: 'core.Webhook', scope: ['$mine'] }
	];
	const carveOutRoles = [
		{
			id: 'iam.Roles.editor',
			data: {
				name: 'editor',
				description: 'Synthetic editor role for the carve-out round trip.',
				visible_tags: ['default'],
				permissions: editorPermissions
			}
		}
	];

	// Synthetic roles for the connectivity-strip stories — mounted through the
	// `roles` prop (same pattern as the carve-out role) so channel state and
	// budget are explicit per story, independent of the mock driver's seeds.
	const connectivityRoles = [
		{
			id: 'iam.Roles.powered',
			data: {
				name: 'powered',
				description: 'Synthetic role with three channels and a token cap.',
				visible_tags: ['default'],
				connectivity: ['mcp', 'api', 'assistant'],
				assistant_token_budget: 500000,
				permissions: []
			}
		}
	];
	const browserOnlyRoles = [
		{
			id: 'iam.Roles.browser_only',
			data: {
				name: 'browser_only',
				description: 'Synthetic browser-only role — no channels, no cap.',
				visible_tags: ['default'],
				connectivity: [],
				permissions: []
			}
		}
	];

	$effect(() => {
		(async () => {
			const [r, d] = await Promise.all([
				driver.domain('iam').doctype('Roles').list(),
				driver.domain('core').doctype('Domain').list()
			]);
			roles = r.data as RoleListItem[];
			domains = d.data.map((item) => ({ id: item.meta.id, data: item.data }));
			loaded = true;
		})();
	});
</script>

<Story
	name="Default"
	args={{ selectedRoleId: '' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No role selected: the domain selector must be hidden and no doctype
		// tree rendered, so the user is not confused by an inactive editor.
		await expect(
			canvas.getByText('Pick a role to edit its per-doctype permissions.')
		).toBeVisible();
		await expect(
			canvas.queryByPlaceholderText('Filter domains and doctypes…')
		).not.toBeInTheDocument();
	}}
>
	{#snippet template(args)}
		{#if loaded}
			<div style="min-height: 80vh">
				<RbacEditorInner
					registry={driver.doctypeDefinitions}
					{roles}
					{domains}
					selectedRoleId={args.selectedRoleId}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading role + domain data…</p>
		{/if}
	{/snippet}
</Story>

<Story
	name="ViewerRole"
	args={{ selectedRoleId: 'viewer' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A role is selected: the domain selector appears so permissions can be
		// edited against the live doctype registry.
		await expect(canvas.getByPlaceholderText('Filter domains and doctypes…')).toBeVisible();
		// The grid exposes tree semantics — one tree, expanded treeitems within.
		await expect(canvas.getByRole('tree', { name: m.admin_tree_aria() })).toBeVisible();
		expect(canvas.getAllByRole('treeitem').length).toBeGreaterThan(0);
	}}
>
	{#snippet template(args)}
		{#if loaded}
			<div style="min-height: 80vh">
				<RbacEditorInner
					registry={driver.doctypeDefinitions}
					{roles}
					{domains}
					selectedRoleId={args.selectedRoleId}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<Story name="EditorRole" args={{ selectedRoleId: 'editor' }}>
	{#snippet template(args)}
		{#if loaded}
			<div style="min-height: 80vh">
				<RbacEditorInner
					registry={driver.doctypeDefinitions}
					{roles}
					{domains}
					selectedRoleId={args.selectedRoleId}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<Story name="AdminRole" args={{ selectedRoleId: 'admin' }}>
	{#snippet template(args)}
		{#if loaded}
			<div style="min-height: 80vh">
				<RbacEditorInner
					registry={driver.doctypeDefinitions}
					{roles}
					{domains}
					selectedRoleId={args.selectedRoleId}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<!-- B-87 — route-gated named actions (the IAM operator actions) must be
	grantable from the editor, not only via REST. The viewer role carries no
	doctype-scoped lines (its wildcard read loads under the `*.*` key, which
	matches no tree row), so the grant starts from a clean row. -->
<Story
	name="RouteGatedActions"
	args={{ selectedRoleId: 'viewer' }}
	play={async ({ canvasElement }) => {
		savedPermissions = [];
		const canvas = within(canvasElement);

		// Expand the whole tree so the iam domain's rows are rendered.
		await userEvent.click(canvas.getByRole('button', { name: 'Expand all' }));

		// The iam.Account row renders one picker per grantable action —
		// including the two route-gated operator actions.
		const accountName = await canvas.findByText('Account', { selector: '.node-name' });
		const accountRow = within(accountName.closest('.node-row') as HTMLElement);
		await expect(accountRow.getByText('Provision Credentials')).toBeVisible();
		await expect(accountRow.getByText('Mfa Disable')).toBeVisible();

		// Grant provision_credentials unrestricted via its own picker.
		const label = accountRow.getByText('Provision Credentials');
		const cell = label.closest('.node-action') as HTMLElement;
		const trigger = cell.querySelector('.scope-select button');
		if (!trigger) throw new Error('provision_credentials picker trigger not found');
		await userEvent.click(trigger);
		await userEvent.click(await within(document.body).findByRole('option', { name: 'All' }));

		// Save and assert the wire payload carries the named-action line —
		// the exact line the ticket used to require REST for.
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => {
			const line = savedPermissions.find(
				(p) => p.action === 'provision_credentials' && p.on === 'iam.Account'
			);
			expect(line).toEqual({ action: 'provision_credentials', on: 'iam.Account' });
		});
	}}
>
	{#snippet template(args)}
		{#if loaded}
			<div style="min-height: 80vh">
				<RbacEditorInner
					registry={driver.doctypeDefinitions}
					{roles}
					{domains}
					selectedRoleId={args.selectedRoleId}
					onsave={async (_roleId, perms) => {
						savedPermissions = perms;
					}}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<!-- The connectivity strip mirrors the role's programmatic powers above the
		grants tree: every channel shows its on/off state, and the assistant token
		cap renders when the assistant channel is open. -->
<Story
	name="ConnectivityStrip"
	args={{ selectedRoleId: 'powered' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// All four vocabulary channels render above the tree.
		await expect(canvas.getByText('mcp', { selector: '.rbac-channel' })).toBeVisible();
		await expect(canvas.getByText('webhook', { selector: '.rbac-channel' })).toBeVisible();
		await expect(canvas.getByText('api', { selector: '.rbac-channel' })).toBeVisible();
		await expect(canvas.getByText('assistant', { selector: '.rbac-channel' })).toBeVisible();
		// State is observable through each chip's title (on vs off).
		await expect(canvas.getByText('mcp', { selector: '.rbac-channel' })).toHaveAttribute(
			'title',
			m.admin_connectivity_channel_on()
		);
		await expect(canvas.getByText('webhook', { selector: '.rbac-channel' })).toHaveAttribute(
			'title',
			m.admin_connectivity_channel_off()
		);
		// The assistant channel is open and the role carries a cap — it renders.
		await expect(canvas.getByText('budget: 500000 tokens')).toBeVisible();
	}}
>
	{#snippet template(args)}
		{#if loaded}
			<div style="min-height: 80vh">
				<RbacEditorInner
					registry={driver.doctypeDefinitions}
					roles={connectivityRoles}
					{domains}
					selectedRoleId={args.selectedRoleId}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<!-- A browser-only role (empty connectivity) shows every channel off, and no
		token cap renders — the assistant door is shut, so the budget is moot. -->
<Story
	name="ConnectivityStripBrowserOnly"
	args={{ selectedRoleId: 'browser_only' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		for (const name of ['mcp', 'webhook', 'api', 'assistant']) {
			const chip = canvas.getByText(name, { selector: '.rbac-channel' });
			await expect(chip).toBeVisible();
			await expect(chip).toHaveAttribute('title', m.admin_connectivity_channel_off());
		}
		await expect(canvas.queryByText(/^budget:/)).not.toBeInTheDocument();
	}}
>
	{#snippet template(args)}
		{#if loaded}
			<div style="min-height: 80vh">
				<RbacEditorInner
					registry={driver.doctypeDefinitions}
					roles={browserOnlyRoles}
					{domains}
					selectedRoleId={args.selectedRoleId}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<!-- B-350 — a save rewrites the whole `permissions` array. The editor renders
		no row for wildcard `*.*` lines, but the seeded roles carry their `except`
		carve-outs on exactly those lines. An edit plus save must keep every
		carve-out line, byte-identical.

		The role mounts through the `roles` prop, not the mock driver: the driver
		merges seed and fixture documents by id, and the fixture variant of the
		`editor` role (data/fixtures/iam.facet-domain) carries bare wildcard lines
		without carve-outs and would replace the seeded one. -->
<Story
	name="WildcardCarveOutsSurvive"
	args={{ selectedRoleId: 'editor' }}
	play={async ({ canvasElement }) => {
		savedPermissions = [];
		const canvas = within(canvasElement);

		// Expand the tree and set one unrelated picker, so the role is dirty.
		await userEvent.click(canvas.getByRole('button', { name: 'Expand all' }));
		const accountName = await canvas.findByText('Account', { selector: '.node-name' });
		const accountRow = within(accountName.closest('.node-row') as HTMLElement);
		const label = accountRow.getByText('Provision Credentials');
		const cell = label.closest('.node-action') as HTMLElement;
		const trigger = cell.querySelector('.scope-select button');
		if (!trigger) throw new Error('provision_credentials picker trigger not found');
		await userEvent.click(trigger);
		await userEvent.click(await within(document.body).findByRole('option', { name: 'All' }));

		// Save: the payload must still carry every wildcard carve-out line.
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await waitFor(() => {
			expect(savedPermissions).toContainEqual({
				action: 'create',
				on: '*.*',
				except: [
					'core.DocType',
					'core.DocumentView',
					'core.DomainEditor',
					'core.SchematicLayout',
					'core.SystemSettings',
					'iam.OIDCProvider'
				]
			});
			expect(savedPermissions).toContainEqual({
				action: 'update',
				on: '*.*',
				except: [
					'core.Domain',
					'core.DocType',
					'core.DocumentView',
					'core.DomainEditor',
					'core.SchematicLayout',
					'core.SystemSettings',
					'iam.OIDCProvider',
					'core.Webhook'
				]
			});
			expect(savedPermissions).toContainEqual({
				action: 'delete',
				on: '*.*',
				except: [
					'core.Domain',
					'core.DocType',
					'core.DocumentView',
					'core.DomainEditor',
					'core.SchematicLayout',
					'core.SystemSettings',
					'iam.OIDCProvider',
					'core.Webhook'
				]
			});
			expect(savedPermissions).toContainEqual({
				action: 'read',
				on: '*.*',
				except: ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook']
			});
		});
	}}
>
	{#snippet template(args)}
		{#if loaded}
			<div style="min-height: 80vh">
				<RbacEditorInner
					registry={driver.doctypeDefinitions}
					roles={carveOutRoles}
					{domains}
					selectedRoleId={args.selectedRoleId}
					onsave={async (_roleId, perms) => {
						savedPermissions = perms;
					}}
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

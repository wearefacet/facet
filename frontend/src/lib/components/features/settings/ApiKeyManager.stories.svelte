<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ApiKeyManager from './ApiKeyManager.svelte';
	import type { ApiKeyRecord, CreatedApiKey, CreateApiKeyInput } from '$lib/iam/apiKeys.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Settings/ApiKeyManager',
		component: ApiKeyManager,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	// ── Fixtures ────────────────────────────────────────────────────────────
	const now = Date.now();
	const iso = (msAgo: number) => new Date(now - msAgo).toISOString();
	const DAY = 86400_000;
	const HOUR = 3600_000;

	const activeKey: ApiKeyRecord = {
		id: 'key-active',
		name: 'CI pipeline',
		display_prefix: 'fct_ci1ab2',
		role_id: 'iam.Roles.editor',
		created_at: iso(3 * DAY),
		expires_at: null,
		last_used_at: iso(2 * HOUR),
		revoked_at: null
	};

	const expiredKey: ApiKeyRecord = {
		id: 'key-expired',
		name: 'Reporting job',
		display_prefix: 'fct_re3cd4',
		role_id: 'iam.Roles.viewer',
		created_at: iso(40 * DAY),
		expires_at: iso(7 * DAY),
		last_used_at: iso(5 * DAY),
		revoked_at: null
	};

	const revokedKey: ApiKeyRecord = {
		id: 'key-revoked',
		name: 'Old deploy key',
		display_prefix: 'fct_ol5ef6',
		role_id: 'iam.Roles.production_editor',
		created_at: iso(90 * DAY),
		expires_at: null,
		last_used_at: iso(60 * DAY),
		revoked_at: iso(20 * DAY)
	};

	const ROLES = ['iam.Roles.viewer', 'iam.Roles.editor'];

	const RAW_KEY = 'fct_zz9y8x7w6v5u4t3s2r1q0ponmlk';

	// Mutable fixtures for the create / revoke flows — the mocks swap them in,
	// so the static stories stay stable.
	let created = false;
	let newRow: ApiKeyRecord = activeKey;
	let revocable = activeKey;

	/** Mock API surface. `rows()` supplies the list result on every call. */
	function mocks(
		rows: () => ApiKeyRecord[],
		createImpl?: (input: CreateApiKeyInput) => Promise<CreatedApiKey>,
		revokeImpl?: (id: string) => Promise<void>
	) {
		return {
			listKeys: async () => rows(),
			createKey:
				createImpl ??
				(async (_input: CreateApiKeyInput) => {
					throw new Error('not expected in this story');
				}),
			revokeKey:
				revokeImpl ??
				(async (_id: string) => {
					throw new Error('not expected in this story');
				})
		};
	}
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import ConfirmDialog from '$lib/components/primitives/surfaces/ConfirmDialog.svelte';
</script>

<!--
	The API surface is injected (`listKeys` / `createKey` / `revokeKey` props),
	so every story runs against mocks — no backend and no `apiFetch` involved.
	Dialogs portal into `document.body`, so the play functions query
	`within(document.body)`.
-->

<Story
	name="ListsKeysWithStatusBadges"
	args={{
		roles: ROLES,
		...mocks(() => [activeKey, expiredKey, revokedKey])
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('CI pipeline')).toBeVisible());

		// Prefix renders in its mono form.
		await expect(canvas.getByText('fct_ci1ab2…')).toBeVisible();
		// Role chips show the humanized role names.
		await expect(canvas.getByText('Editor')).toBeVisible();
		await expect(canvas.getByText('Viewer')).toBeVisible();
		await expect(canvas.getByText('Production Editor')).toBeVisible();
		// Status badges.
		await expect(canvas.getByText('Active')).toBeVisible();
		await expect(canvas.getByText('Expired')).toBeVisible();
		await expect(canvas.getByText('Revoked')).toBeVisible();
		// The revoked row has no revoke action; the two live rows do.
		await expect(canvas.queryAllByRole('button', { name: 'Revoke' })).toHaveLength(2);
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<ApiKeyManager
				roles={args.roles}
				listKeys={args.listKeys}
				createKey={args.createKey}
				revokeKey={args.revokeKey}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyState"
	args={{
		roles: ROLES,
		...mocks(() => [])
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText(/No API keys yet/)).toBeVisible());
		await expect(canvas.getByRole('button', { name: 'Create key' })).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<ApiKeyManager
				roles={args.roles}
				listKeys={args.listKeys}
				createKey={args.createKey}
				revokeKey={args.revokeKey}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CreateFlowRevealsKeyOnce"
	args={{
		roles: ROLES,
		...mocks(
			() => (created ? [newRow, activeKey] : [activeKey]),
			async (input: CreateApiKeyInput) => {
				created = true;
				newRow = {
					id: 'key-new',
					name: input.name,
					display_prefix: 'fct_ne7gh8',
					role_id: input.role,
					created_at: new Date().toISOString(),
					expires_at: input.expires_at ?? null,
					last_used_at: null,
					revoked_at: null
				};
				return {
					id: 'key-new',
					key: RAW_KEY,
					display_prefix: 'fct_ne7gh8',
					expires_at: input.expires_at ?? null
				};
			}
		)
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const body = within(document.body);
		await waitFor(() => expect(canvas.getByText('CI pipeline')).toBeVisible());

		// Open the create dialog and fill the form. Both the screen's opener
		// and the dialog's submit are named "Create key" — the dialog's submit
		// is the last one in the DOM (portal is appended after the canvas).
		await userEvent.click(canvas.getByRole('button', { name: 'Create key' }));
		await waitFor(() => expect(body.getByText('New API key')).toBeVisible());
		await userEvent.type(body.getByPlaceholderText('e.g. CI pipeline'), 'Import bot');
		const picker = body.getByPlaceholderText('Pick the role this key acts as');
		await picker.focus();
		await waitFor(() => expect(body.getByRole('option', { name: 'Viewer' })).toBeVisible());
		await userEvent.click(body.getByRole('option', { name: 'Viewer' }));
		const createButtons = body.getAllByRole('button', { name: 'Create key' });
		await userEvent.click(createButtons[createButtons.length - 1]);

		// The reveal dialog shows the raw key exactly once, with a copy button.
		await waitFor(() => expect(body.getByText('API key created')).toBeVisible());
		await expect(body.getByText(RAW_KEY)).toBeVisible();
		// Headless Chromium may reject clipboard writes; stub the API so the
		// click deterministically reaches the "Copied" state.
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: async () => {} },
			configurable: true
		});
		await userEvent.click(body.getByRole('button', { name: 'Copy' }));
		await waitFor(() => {
			expect(body.getByRole('button', { name: 'Copied' })).toBeVisible();
		});

		// Done closes the reveal dialog; the list shows the new key's prefix —
		// never the raw secret.
		await userEvent.click(body.getByRole('button', { name: 'Done' }));
		await waitFor(() => {
			expect(body.queryByText('API key created')).toBeNull();
		});
		await waitFor(() => expect(canvas.getByText('Import bot')).toBeVisible());
		await expect(canvas.getByText('fct_ne7gh8…')).toBeVisible();
		await expect(canvas.queryByText(RAW_KEY)).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<ApiKeyManager
				roles={args.roles}
				listKeys={args.listKeys}
				createKey={args.createKey}
				revokeKey={args.revokeKey}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="RevokeFlowGoesThroughConfirmDialog"
	args={{
		roles: ROLES,
		...mocks(
			() => [revocable, revokedKey],
			undefined,
			async () => {
				revocable = { ...activeKey, revoked_at: new Date().toISOString() };
			}
		)
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const body = within(document.body);
		await waitFor(() => expect(canvas.getByText('CI pipeline')).toBeVisible());

		// A story that just closed a dialog leaves `pointer-events: none` on
		// <body> for a tick — wait for it to clear, tolerating the transient
		// state, before the first canvas click.
		const revokeBtn = canvas.getByRole('button', { name: 'Revoke' });
		await waitFor(async () => {
			expect(document.body.style.pointerEvents).not.toBe('none');
			await userEvent.click(revokeBtn);
		});
		await waitFor(() => expect(body.getByText('Revoke “CI pipeline”?')).toBeVisible());

		// Cancelling keeps the key active.
		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await expect(canvas.getByText('Active')).toBeVisible();

		// Confirming revokes: the row flips to the Revoked badge.
		const revokeBtn2 = canvas.getByRole('button', { name: 'Revoke' });
		await waitFor(async () => {
			expect(document.body.style.pointerEvents).not.toBe('none');
			await userEvent.click(revokeBtn2);
		});
		await waitFor(() => expect(body.getByText('Revoke “CI pipeline”?')).toBeVisible());
		await userEvent.click(body.getByRole('button', { name: 'Revoke key' }));
		await waitFor(() => {
			expect(canvas.getAllByText('Revoked')).toHaveLength(2);
		});
		// The revoked row no longer offers a revoke action.
		await expect(canvas.queryByRole('button', { name: 'Revoke' })).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<ApiKeyManager
				roles={args.roles}
				listKeys={args.listKeys}
				createKey={args.createKey}
				revokeKey={args.revokeKey}
			/>
			<!-- The confirm host lives in the root layout in the app; the story
				must mount it explicitly or `confirm()` would never render. -->
			<ConfirmDialog />
		</div>
	{/snippet}
</Story>

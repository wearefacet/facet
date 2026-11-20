<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import Sessions from './Sessions.svelte';
	import type { AccountSession } from './SessionsSource.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Settings/Sessions',
		component: Sessions,
		tags: ['autodocs']
	});

	// ── Fixtures ────────────────────────────────────────────────────────────
	const now = Date.now();
	const iso = (msAgo: number) => new Date(now - msAgo).toISOString();
	const HOUR = 3600_000;
	const DAY = 86400_000;

	// Newest creation first — the component sorts, so the fixture ages set
	// the expected row order (desktop, laptop, app).
	const desktop: AccountSession = {
		session_id: '01JSESS0000000000000000D1',
		created_at: iso(30 * DAY),
		last_used: iso(2 * HOUR),
		user_agent:
			'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
		ip: '203.0.113.7',
		app: null,
		role: 'iam.Roles.admin'
	};

	const laptop: AccountSession = {
		session_id: '01JSESS0000000000000000D2',
		created_at: iso(9 * DAY),
		last_used: iso(3 * DAY),
		user_agent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Firefox/128.0',
		ip: '198.51.100.23',
		app: null,
		role: 'iam.Roles.editor'
	};

	const appSession: AccountSession = {
		session_id: '01JSESS0000000000000000A1',
		created_at: iso(5 * DAY),
		last_used: iso(20 * 60_000),
		user_agent: null,
		ip: '192.0.2.44',
		app: '01JAPPULID0000000000000000X',
		role: 'iam.Roles.viewer'
	};

	// Mutable fixture for the revoke flows — the mocks swap it, so the
	// static stories stay stable.
	let others: AccountSession[] = [laptop, appSession];

	const resetOthers = () => {
		others = [laptop, appSession];
	};

	/** Mock API surface. `rows()` supplies the list result on every call. */
	function mocks(
		rows: () => AccountSession[],
		revokeImpl?: (id: string) => Promise<void>,
		revokeAllImpl?: () => Promise<number>
	) {
		return {
			listSessions: async () => rows(),
			revokeSession:
				revokeImpl ??
				(async (_id: string) => {
					throw new Error('not expected in this story');
				}),
			revokeAllSessions:
				revokeAllImpl ??
				(async () => {
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
	The API surface is injected (`listSessions` / `revokeSession` /
	`revokeAllSessions` props), so every story runs against mocks — no
	backend and no `apiFetch` involved. Dialogs portal into `document.body`,
	so the play functions query `within(document.body)`.
-->

<Story
	name="ListsSessions"
	args={{ ...mocks(() => [desktop, laptop, appSession]) }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('203.0.113.7')).toBeVisible());

		// Every session renders: the UA (or the fallback), the IP, the role.
		await expect(canvas.getByText('198.51.100.23')).toBeVisible();
		await expect(canvas.getByText('192.0.2.44')).toBeVisible();
		await expect(canvas.getByText('Unknown device')).toBeVisible();
		await expect(canvas.getByText('Admin')).toBeVisible();
		await expect(canvas.getByText('Editor')).toBeVisible();
		await expect(canvas.getByText('Viewer')).toBeVisible();
		// The app session carries its app id (the full ULID as the title).
		await expect(canvas.getByText('01JAPPULID0000000000000000X')).toBeVisible();
		// One revoke per row + the bulk action.
		await expect(canvas.getAllByRole('button', { name: 'Revoke' })).toHaveLength(3);
		await expect(canvas.getByRole('button', { name: 'Revoke other sessions' })).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<Sessions
				listSessions={args.listSessions}
				revokeSession={args.revokeSession}
				revokeAllSessions={args.revokeAllSessions}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyState"
	args={{ ...mocks(() => []) }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText(/No active sessions/)).toBeVisible());
		// Nothing to revoke — the bulk action sits disabled.
		await expect(canvas.getByRole('button', { name: 'Revoke other sessions' })).toBeDisabled();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<Sessions
				listSessions={args.listSessions}
				revokeSession={args.revokeSession}
				revokeAllSessions={args.revokeAllSessions}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="LoadError"
	args={{
		...mocks(() => {
			throw new Error('backend down');
		})
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);

		// `errorMessage` renders the Error's own message; the alert proves the
		// load-error path surfaced it.
		const alert = await waitFor(() => canvas.getByRole('alert'));

		await expect(alert).toHaveTextContent('backend down');
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<Sessions
				listSessions={args.listSessions}
				revokeSession={args.revokeSession}
				revokeAllSessions={args.revokeAllSessions}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="RevokeOneGoesThroughConfirm"
	args={{
		...mocks(
			() => [desktop, ...others],
			async (id) => {
				others = others.filter((s) => s.session_id !== id);
			}
		)
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const body = within(document.body);
		resetOthers();
		await waitFor(() => expect(canvas.getByText('203.0.113.7')).toBeVisible());

		// The row buttons share the visible label; scope by row. A story that
		// just closed a dialog leaves `pointer-events: none` on <body> for a
		// tick — wait for it to clear before the click (see ApiKeyManager).
		const rowFor = (ip: string) => {
			const row = canvas.getByText(ip).closest('li');
			if (!row) throw new Error(`row for ${ip} not found`);
			return row;
		};
		const revokeBtn = within(rowFor('198.51.100.23')).getByRole('button', { name: 'Revoke' });
		await waitFor(async () => {
			expect(document.body.style.pointerEvents).not.toBe('none');
			await userEvent.click(revokeBtn);
		});
		await waitFor(() => expect(body.getByText('Revoke this session?')).toBeVisible());

		// Cancelling keeps the session listed.
		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByText('Revoke this session?')).toBeNull());
		await expect(canvas.getByText('198.51.100.23')).toBeVisible();

		// Confirming removes the row after the refresh.
		const revokeBtn2 = within(rowFor('198.51.100.23')).getByRole('button', { name: 'Revoke' });
		await waitFor(async () => {
			expect(document.body.style.pointerEvents).not.toBe('none');
			await userEvent.click(revokeBtn2);
		});
		await waitFor(() => expect(body.getByText('Revoke this session?')).toBeVisible());
		await userEvent.click(body.getByRole('button', { name: 'Revoke session' }));
		await waitFor(() => expect(canvas.queryByText('198.51.100.23')).toBeNull());
		// The untouched rows stay.
		await expect(canvas.getByText('203.0.113.7')).toBeVisible();
		await expect(canvas.getByText('192.0.2.44')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<Sessions
				listSessions={args.listSessions}
				revokeSession={args.revokeSession}
				revokeAllSessions={args.revokeAllSessions}
			/>
			<!-- The confirm host lives in the root layout in the app; the story
				must mount it explicitly or `confirm()` would never render. -->
			<ConfirmDialog />
		</div>
	{/snippet}
</Story>

<Story
	name="RevokeAllOthersThroughConfirm"
	args={{
		...mocks(
			() => [desktop, ...others],
			undefined,
			async () => {
				const n = others.length;
				others = [];
				return n;
			}
		)
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const body = within(document.body);
		resetOthers();
		await waitFor(() => expect(canvas.getByText('203.0.113.7')).toBeVisible());
		await expect(canvas.getByText('198.51.100.23')).toBeVisible();

		const bulkBtn = canvas.getByRole('button', { name: 'Revoke other sessions' });
		await waitFor(async () => {
			expect(document.body.style.pointerEvents).not.toBe('none');
			await userEvent.click(bulkBtn);
		});
		await waitFor(() => expect(body.getByText('Revoke all other sessions?')).toBeVisible());
		await userEvent.click(body.getByRole('button', { name: 'Revoke others' }));

		// The other rows disappear; the status line reports the count.
		await waitFor(() => expect(canvas.queryByText('198.51.100.23')).toBeNull());
		await expect(canvas.queryByText('192.0.2.44')).toBeNull();
		await expect(canvas.getByText('Revoked 2 other sessions.')).toBeVisible();
		// The current session's row stays listed.
		await expect(canvas.getByText('203.0.113.7')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground); min-height: 400px;">
			<Sessions
				listSessions={args.listSessions}
				revokeSession={args.revokeSession}
				revokeAllSessions={args.revokeAllSessions}
			/>
			<!-- The confirm host lives in the root layout in the app; the story
				must mount it explicitly or `confirm()` would never render. -->
			<ConfirmDialog />
		</div>
	{/snippet}
</Story>

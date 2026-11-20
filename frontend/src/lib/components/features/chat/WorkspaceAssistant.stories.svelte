<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import WorkspaceAssistant from './WorkspaceAssistant.svelte';
	import WorkspaceAssistantFixture from './WorkspaceAssistantFixture.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import {
		MockAssistantDriver,
		MOCK_WORKSPACE_ACCOUNT_ID,
		collapseContentChunks,
		defaultScripts,
		workspaceScript,
		workspaceFixtureDocumentIds,
		workspaceFixtureNames,
		type Conversation
	} from '$lib/assistant/index.js';
	import { ulid } from '$lib/assistant/mock/conversation.js';

	/**
	 * Wait budget for a scripted reply inside a play. Must stay well below
	 * the storybook project `testTimeout` (10s in `vite.config.ts`): when the
	 * two budgets tie, the test-level timeout fires first and hides which
	 * wait failed.
	 */
	const REPLY_TIMEOUT_MS = 5_000;

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/WorkspaceAssistant',
		component: WorkspaceAssistant,
		tags: ['autodocs'],
		argTypes: {
			accountId: { control: 'text' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/**
	 * Builds a MockAssistantDriver seeded with two workspace conversations
	 * (owned by {@link MOCK_WORKSPACE_ACCOUNT_ID}), one domain-builder
	 * conversation, and another account's workspace conversation. The
	 * created_by filter must hide the last two.
	 *
	 * The workspace script runs collapsed (see
	 * {@link collapseContentChunks}): a play streams one full turn per send,
	 * and the word-by-word default costs one thread re-render per chunk —
	 * slow enough on CI runners to outrun the per-test timeout.
	 */
	function makeDriver(): MockAssistantDriver {
		const driver = new MockAssistantDriver([
			collapseContentChunks(workspaceScript),
			...defaultScripts
		]);
		const now = Date.now();
		const seeds: Record<string, unknown>[] = [
			{ kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID },
			{ kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID },
			{ kind: 'domain-builder', draft_domain: '_draft_other' },
			{ kind: 'workspace', created_by: 'core.account_someone_else' }
		];
		for (const context of seeds) {
			const conv: Conversation = {
				id: ulid(),
				session_id: ulid(),
				cache_key: ulid(),
				system_prompt: 'You are a helpful assistant.',
				context,
				enabled_tools: [],
				created_at: new Date(now).toISOString(),
				updated_at: new Date(now).toISOString(),
				archived_at: null,
				active: false
			};
			driver.seedConversation(conv);
		}
		return driver;
	}

	/**
	 * Document records for the workspace surfaces the scripted turn renders —
	 * the same seeding shape as the app's `DocumentDataDriver`. The fixture
	 * definitions and views come with the script's crm.Customer documents.
	 */
	function makeDataDriver(): MockDataDriver {
		const data = new MockDataDriver();
		data.registerDoctype('crm', 'Customer', {
			doctype: 'Customer',
			domain: 'crm',
			icon: 'building-2',
			fields: {
				name: { key: 'name', type: 'text', title: 'Name' },
				status: { key: 'status', type: 'enum', title: 'Status' }
			}
		});
		void data.domain('crm').doctype(
			'Customer',
			workspaceFixtureNames.map((name) => ({
				id: workspaceFixtureDocumentIds[workspaceFixtureNames.indexOf(name)],
				name,
				status: 'active'
			}))
		);
		void data
			.domain('core')
			.doctype('DocType', [{ id: 'crm.Customer', doctype: 'Customer', domain: 'crm' }]);
		void data.domain('core').doctype('DocumentView', [
			{
				id: 'crm.Customer.document_view.card',
				kind: 'card',
				template: {
					type: 'col',
					children: [
						{
							type: 'section',
							label: 'Identity',
							children: [{ type: 'field', label: 'Name', value: '$name' }]
						}
					]
				}
			}
		]);
		return data;
	}

	const accountId = MOCK_WORKSPACE_ACCOUNT_ID;
</script>

<script lang="ts">
	import { clearAssistantStorage } from './assistantWindowState.js';

	// Bump to re-mount the fixture after a reset — each play starts from a
	// clean hydration, whichever story ran before it.
	let remounts = $state(0);

	// Fresh driver instances for every play (see `resetPlay`). The template
	// snippets read these bindings.
	let driver = $state(makeDriver());
	let documentDriver = $state(makeDataDriver());

	/**
	 * Resets everything a play leaves behind: the persisted assistant window
	 * state, and the drivers' in-memory stores. This page is long-lived and
	 * shared (`isolate: false` in `vite.config.ts`) — stories and retry
	 * attempts run against the same module state, so a retry must not see
	 * the conversations a failed attempt created. The rail would then render
	 * one extra row, and count assertions would fail.
	 */
	function resetPlay(): void {
		clearAssistantStorage();
		driver = makeDriver();
		documentDriver = makeDataDriver();
	}

	/** Waits out the `{#key}` re-mount: the swap flushes on a microtask, and
	 * a query issued in the same tick can still reach the outgoing fixture.
	 * One macrotask later every pending render + mount effect has run. */
	function settle(ms = 50): Promise<void> {
		return new Promise((resolve) => setTimeout(resolve, ms));
	}
</script>

<Story
	name="ToggleHiddenWithoutAccess"
	play={async ({ canvasElement }) => {
		resetPlay();
		remounts++;
		await settle();
		const canvas = within(canvasElement);
		// No held role carries `assistant_access` — the top bar carries no
		// assistant toggle at all, and no window mounts.
		await expect(
			canvas.queryByRole('button', { name: 'Toggle assistant' })
		).not.toBeInTheDocument();
		await expect(canvas.queryByRole('dialog', { name: 'Assistant' })).not.toBeInTheDocument();
	}}
>
	{#snippet template()}
		<div class="frame">
			{#key remounts}
				<WorkspaceAssistantFixture {accountId} access={false} />
			{/key}
		</div>
	{/snippet}
</Story>

<Story
	name="ToggleOpensWindow"
	play={async ({ canvasElement }) => {
		resetPlay();
		remounts++;
		await settle();
		const canvas = within(canvasElement);

		// Access granted — the toggle renders, starts unpressed, and opens
		// the window.
		const toggleBtn = await waitFor(() => canvas.getByRole('button', { name: 'Toggle assistant' }));
		await expect(toggleBtn).toHaveAttribute('aria-pressed', 'false');
		await userEvent.click(toggleBtn);

		const win = await waitFor(() => canvas.getByRole('dialog', { name: 'Assistant' }));
		await expect(toggleBtn).toHaveAttribute('aria-pressed', 'true');

		// The list shows only this account's workspace conversations — the
		// builder row and the other account's workspace row stay hidden.
		await waitFor(async () => {
			await expect(within(win).getAllByText('workspace conversation').length).toBe(2);
		});
		await expect(within(win).queryAllByText('domain-builder conversation').length).toBe(0);

		// The window is functional: a message goes out and the scripted reply
		// streams back.
		const winScope = within(win);
		await userEvent.type(winScope.getByRole('textbox'), 'find my active customers');
		await userEvent.click(winScope.getByRole('button', { name: 'Send message' }));
		await expect(winScope.getByText('find my active customers')).toBeVisible();
		await waitFor(
			async () => {
				await expect(winScope.getByText(/anything else/)).toBeVisible();
			},
			{ timeout: REPLY_TIMEOUT_MS }
		);
	}}
>
	{#snippet template()}
		<div class="frame">
			{#key remounts}
				<WorkspaceAssistantFixture {accountId} {driver} {documentDriver} access={true} />
			{/key}
		</div>
	{/snippet}
</Story>

<Story
	name="OpenStateSurvivesRemount"
	play={async ({ canvasElement }) => {
		resetPlay();
		remounts++;
		await settle();
		const canvas = within(canvasElement);

		// Open the window, then force a full fixture remount — the persisted
		// open state must re-apply from sessionStorage without a click.
		await userEvent.click(
			await waitFor(() => canvas.getByRole('button', { name: 'Toggle assistant' }))
		);
		await waitFor(async () => {
			await expect(canvas.getByRole('dialog', { name: 'Assistant' })).toBeInTheDocument();
		});

		remounts++;
		await settle();
		await waitFor(async () => {
			await expect(canvas.getByRole('dialog', { name: 'Assistant' })).toBeInTheDocument();
		});
		await expect(canvas.getByRole('button', { name: 'Toggle assistant' })).toHaveAttribute(
			'aria-pressed',
			'true'
		);

		// Closing from the window header also persists across a remount.
		const win = canvas.getByRole('dialog', { name: 'Assistant' });
		await userEvent.click(within(win).getByRole('button', { name: 'Close assistant' }));
		remounts++;
		await settle();
		await waitFor(async () => {
			await expect(canvas.queryByRole('dialog', { name: 'Assistant' })).not.toBeInTheDocument();
		});
	}}
>
	{#snippet template()}
		<div class="frame">
			{#key remounts}
				<WorkspaceAssistantFixture {accountId} {driver} {documentDriver} access={true} />
			{/key}
		</div>
	{/snippet}
</Story>

<Story
	name="ThreadKeepsContentAcrossCollapse"
	play={async ({ canvasElement }) => {
		resetPlay();
		remounts++;
		await settle();
		const canvas = within(canvasElement);

		// Open the window and put content in the thread: send a message and
		// wait for the scripted reply to finish streaming.
		await userEvent.click(
			await waitFor(() => canvas.getByRole('button', { name: 'Toggle assistant' }))
		);
		const win = await waitFor(() => canvas.getByRole('dialog', { name: 'Assistant' }));
		const winScope = within(win);
		await userEvent.type(winScope.getByRole('textbox'), 'find my active customers');
		await userEvent.click(winScope.getByRole('button', { name: 'Send message' }));
		await expect(winScope.getByText('find my active customers')).toBeVisible();
		await waitFor(
			async () => {
				await expect(winScope.getByText(/anything else/)).toBeVisible();
			},
			{ timeout: REPLY_TIMEOUT_MS }
		);

		// Collapse. The body hides with display:none — the thread content
		// must stay in the DOM. An unmount here is the regression: after the
		// expand the thread would come back empty.
		await userEvent.click(winScope.getByRole('button', { name: 'Collapse assistant' }));
		await expect(winScope.getByText('find my active customers')).toBeInTheDocument();

		// Expand again — the same conversation and turns are still on
		// screen, with no reselect from the rail.
		await userEvent.click(winScope.getByRole('button', { name: 'Expand assistant' }));
		await expect(winScope.getByText('find my active customers')).toBeVisible();
		await expect(winScope.getByText(/anything else/)).toBeVisible();
	}}
>
	{#snippet template()}
		<div class="frame">
			{#key remounts}
				<WorkspaceAssistantFixture {accountId} {driver} {documentDriver} access={true} />
			{/key}
		</div>
	{/snippet}
</Story>

<Story
	name="CollapseFromMaximizedShrinksToTitleBar"
	play={async ({ canvasElement }) => {
		resetPlay();
		remounts++;
		await settle();
		const canvas = within(canvasElement);

		await userEvent.click(
			await waitFor(() => canvas.getByRole('button', { name: 'Toggle assistant' }))
		);
		const win = await waitFor(() => canvas.getByRole('dialog', { name: 'Assistant' }));
		const winScope = within(win);

		// Maximize, then minimize. The minimized window must be the docked
		// title bar (40px) — the full-viewport empty box here is the
		// regression: the maximized geometry used to win while the body was
		// hidden.
		await userEvent.click(winScope.getByRole('button', { name: 'Maximize assistant' }));
		await expect(winScope.getByRole('button', { name: 'Restore assistant' })).toBeInTheDocument();
		await userEvent.click(winScope.getByRole('button', { name: 'Collapse assistant' }));
		await waitFor(() => {
			expect(win.style.height).toBe('40px');
		});

		// Maximize survives under the minimize — expand returns to the
		// maximized box (viewport minus a 16px gap on each side), not the
		// floating default.
		await userEvent.click(winScope.getByRole('button', { name: 'Expand assistant' }));
		const maximizedHeight = `${window.innerHeight - 32}px`;
		await waitFor(() => {
			expect(win.style.height).toBe(maximizedHeight);
		});
		await expect(winScope.getByRole('button', { name: 'Restore assistant' })).toBeInTheDocument();
	}}
>
	{#snippet template()}
		<div class="frame">
			{#key remounts}
				<WorkspaceAssistantFixture {accountId} {driver} {documentDriver} access={true} />
			{/key}
		</div>
	{/snippet}
</Story>

<Story name="Bare">
	{#snippet template()}
		<div class="frame frame-bare">
			<WorkspaceAssistant {accountId} {driver} {documentDriver} />
		</div>
	{/snippet}
</Story>

<style>
	.frame {
		position: relative;
		width: 100%;
		height: 80vh;
		min-height: 560px;
		overflow: hidden;
		background: var(--bg, var(--surface));
	}

	/* Bare mounts the window alone (no shell) against a page backdrop. */
	.frame-bare {
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
	}
</style>

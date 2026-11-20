<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ConversationList from './ConversationList.svelte';
	import { MockAssistantDriver } from '$lib/assistant/index.js';
	import type { Conversation } from '$lib/assistant/index.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ConversationList',
		component: ConversationList,
		tags: ['autodocs'],
		argTypes: {
			pageSize: { control: 'number' }
		}
	});
</script>

<script lang="ts">
	import { ulid } from '$lib/assistant/mock/conversation.js';
	import { expect, waitFor, within, userEvent } from 'storybook/test';

	/**
	 * Builds a MockAssistantDriver pre-seeded with conversations across
	 * `test`, `domain-builder`, and `general-assistance` contexts, with
	 * staggered `updated_at` timestamps so the ordering is visible.
	 */
	function makeDriver(opts?: { count?: number; kinds?: string[] }): MockAssistantDriver {
		const count = opts?.count ?? 28;
		const kinds = opts?.kinds ?? ['test', 'domain-builder', 'general-assistance'];
		const driver = new MockAssistantDriver();
		const now = Date.now();
		for (let i = 0; i < count; i++) {
			const kind = kinds[i % kinds.length]!;
			const ctx: Record<string, unknown> = { kind };
			if (kind === 'domain-builder') {
				ctx.draft_domain = `_draft_${i}`;
			}
			const conv: Conversation = {
				id: ulid(),
				session_id: ulid(),
				cache_key: ulid(),
				system_prompt: 'You are a helpful assistant.',
				context: ctx,
				enabled_tools: [],
				created_at: new Date(now - (count - i) * 60_000).toISOString(),
				updated_at: new Date(now - (count - i) * 60_000).toISOString(),
				archived_at: null,
				active: false
			};
			driver.seedConversation(conv);
		}
		return driver;
	}

	/** Seeds one archived conversation so the archive toggle has a row to show. */
	function makeDriverWithArchived(): MockAssistantDriver {
		const driver = makeDriver({ count: 3 });
		const now = Date.now();
		const conv: Conversation = {
			id: ulid(),
			session_id: ulid(),
			cache_key: ulid(),
			system_prompt: 'You are a helpful assistant.',
			context: { kind: 'test' },
			enabled_tools: [],
			created_at: new Date(now - 90_000).toISOString(),
			updated_at: new Date(now - 90_000).toISOString(),
			archived_at: new Date(now - 60_000).toISOString(),
			active: false
		};
		driver.seedConversation(conv);
		return driver;
	}

	const driver = makeDriver({ count: 28 });
	const testOnlyDriver = makeDriver({ count: 14, kinds: ['test'] });
	const archiveDriver = makeDriverWithArchived();

	/** One conversation with a running turn — the rail's generating marker. */
	const runningDriver = makeDriver({ count: 4 });
	{
		const now = Date.now();
		const conv: Conversation = {
			id: ulid(),
			session_id: ulid(),
			cache_key: ulid(),
			system_prompt: 'You are a helpful assistant.',
			context: { kind: 'test' },
			enabled_tools: [],
			created_at: new Date(now).toISOString(),
			updated_at: new Date(now).toISOString(),
			archived_at: null,
			active: false
		};
		runningDriver.seedConversation(conv);
		runningDriver.seedRunningTurn(conv.id, 'Summarise the suppliers', 'story-turn-token');
	}

	let selected = $state<string | undefined>(undefined);
</script>

<Story name="Default">
	{#snippet template()}
		<div
			style="position: relative; width: 320px; height: 80vh; min-height: 500px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ConversationList
				{driver}
				context={{}}
				pageSize={6}
				selectedId={selected}
				onselect={(c) => (selected = c.id)}
			/>
		</div>
	{/snippet}
</Story>

<Story name="FilteredByTestContext">
	{#snippet template()}
		<div
			style="position: relative; width: 320px; height: 80vh; min-height: 500px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ConversationList driver={testOnlyDriver} context={{ kind: 'test' }} pageSize={5} />
		</div>
	{/snippet}
</Story>

<Story name="WithNewButton">
	{#snippet template()}
		<div
			style="position: relative; width: 320px; height: 80vh; min-height: 500px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ConversationList
				{driver}
				context={{}}
				pageSize={6}
				onnew={() => alert('would create a new conversation')}
			/>
		</div>
	{/snippet}
</Story>

<Story name="Empty">
	{#snippet template()}
		<div
			style="position: relative; width: 320px; height: 80vh; min-height: 500px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ConversationList driver={new MockAssistantDriver()} context={{ kind: 'test' }} />
		</div>
	{/snippet}
</Story>

<Story
	name="RunningMarker"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The conversation with a running turn renders the generating marker.
		await waitFor(async () => {
			await expect(canvas.getByLabelText('Generating a reply…')).toBeVisible();
		});
	}}
>
	{#snippet template()}
		<div
			style="position: relative; width: 320px; height: 80vh; min-height: 500px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ConversationList driver={runningDriver} context={{}} pageSize={6} />
		</div>
	{/snippet}
</Story>

<Story
	name="ArchiveFlow"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => {
			// The archived row is hidden from the default (live) list: only the
			// three live rows render row actions.
			expect(canvas.getAllByRole('button', { name: /Archive conversation/ }).length).toBe(3);
		});

		// The header archive toggle swaps to the archived list.
		await userEvent.click(canvas.getByRole('button', { name: 'Show archived conversations' }));
		await waitFor(() => {
			expect(canvas.getAllByRole('button', { name: /Unarchive conversation/ }).length).toBe(1);
		});

		// Unarchive moves the row back to the live list. The row action is
		// hover/focus-revealed; synthetic clicks never trigger :hover, so
		// focus the action first — :focus-within enables the pointer.
		const unarchive = canvas.getByRole('button', { name: 'Unarchive conversation' });
		unarchive.focus();
		await userEvent.click(unarchive);
		await waitFor(() => {
			expect(canvas.queryAllByRole('button', { name: /Unarchive conversation/ }).length).toBe(0);
		});
		await userEvent.click(canvas.getByRole('button', { name: 'Show archived conversations' }));
		await waitFor(() => {
			// The unarchived row rejoined the live list — 4 archive actions now.
			expect(canvas.getAllByRole('button', { name: /Archive conversation/ }).length).toBe(4);
		});
	}}
>
	{#snippet template()}
		<div
			style="position: relative; width: 320px; height: 80vh; min-height: 500px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ConversationList driver={archiveDriver} context={{}} pageSize={5} />
		</div>
	{/snippet}
</Story>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!-- TEMPORARY isolated reproduction — see doc/plan/qa-bugs/chat-panel-reselect-busy-lock.md.
     Delete when the bug is resolved. -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import ChatPanel from './ChatPanel.svelte';
	import {
		MockAssistantDriver,
		MOCK_WORKSPACE_ACCOUNT_ID,
		type AssistantDriver,
		type Conversation
	} from '$lib/assistant/index.js';

	// One driver, two conversations, both with a seeded running turn:
	// - `gen` keeps running for the whole story (the orphaned turn a reload
	//   produces);
	// - `idle` is settled immediately (the state a finished turn has).
	const driver = new MockAssistantDriver();
	const gen: Conversation = driver.createConversationSync({
		context: { kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID }
	});
	driver.seedRunningTurn(gen.id, 'still there?', 'gen-turn-token');

	const idle: Conversation = driver.createConversationSync({
		context: { kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID }
	});
	driver.seedRunningTurn(idle.id, 'hello idle', 'idle-turn-token');
	driver.settleRunningTurn(idle.id, 'Idle reply.');

	const { Story } = defineMeta({
		title: 'Debug/ReproReselect',
		component: ChatPanel,
		tags: ['autodocs'],
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	async function createReproConversation(): Promise<Conversation> {
		return Promise.resolve(gen);
	}
</script>

<Story
	name="ReselectLocksComposer"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const textarea = () => canvas.getByRole('textbox') as HTMLTextAreaElement;
		// Rail rows render the auto-title (first user message). The first
		// match is the rail row; the thread repeats the text of the selected
		// conversation below it.
		const rowOf = (title: string) => canvas.getAllByText(title)[0]!;

		// 1. Select the generating conversation — the composer locks.
		await waitFor(() => expect(rowOf('still there?')).toBeVisible());
		await userEvent.click(rowOf('still there?'));
		await waitFor(async () => {
			await expect(canvas.getByText('Thinking…')).toBeVisible();
		});
		await waitFor(async () => {
			await expect(textarea().disabled).toBe(true);
		});

		// 2. Switch to the idle conversation — the composer unlocks.
		console.log('REPRO step 2 click idle');
		await waitFor(async () => {
			await userEvent.click(rowOf('hello idle'));
			await expect(canvas.getByText('Idle reply.')).toBeVisible();
		});
		console.log('REPRO step 2 idle visible');
		await waitFor(async () => {
			await expect(textarea().disabled).toBe(false);
		});
		console.log('REPRO step 2 unlocked');

		// 3. Switch back to the generating conversation — the composer must
		// lock again. THIS IS THE STEP THAT FAILS.
		console.log('REPRO step 3 click generating');
		await waitFor(async () => {
			await userEvent.click(rowOf('still there?'));
			await expect(canvas.getByText('Thinking…')).toBeVisible();
		});
		await waitFor(async () => {
			await expect(textarea().disabled).toBe(true);
		});
	}}
>
	{#snippet template()}
		<div
			style="position: relative; display: flex; width: 760px; height: 80vh; min-height: 560px; overflow: hidden; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg);"
		>
			<ChatPanel
				driver={driver as AssistantDriver}
				context={{ kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID }}
				createConversation={createReproConversation}
				agentName="Kara"
				agentTag="workspace"
			/>
		</div>
	{/snippet}
</Story>

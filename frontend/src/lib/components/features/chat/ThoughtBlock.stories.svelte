<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within, waitFor } from 'storybook/test';
	import ThoughtBlock from './ThoughtBlock.svelte';
	import {
		MockAssistantDriver,
		reasoningChunks,
		type AssistantScript
	} from '$lib/assistant/index.js';
	import type { Conversation } from '$lib/assistant/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ThoughtBlock',
		component: ThoughtBlock,
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	import { onMount } from 'svelte';

	const REASONING =
		'The user wants shipments in a new `logistics` domain. Shipment is the natural aggregate root; addresses are embedded objects, status is an enum, and the customer is a cross-domain reference into `crm.Customer`.';

	// ── Live streaming state for the collapse behavioural story ──────────────
	const thoughtScript: AssistantScript = {
		match: () => true,
		chunks: reasoningChunks('I am thinking through the domain model first. '),
		outcome: { kind: 'done', finish_reason: 'stop' }
	};
	const driver = new MockAssistantDriver([thoughtScript]);
	const conversation: Conversation = driver.createConversationSync({});

	let streamed = $state('');
	let active = $state(true);

	onMount(() => {
		streamThought();
	});

	async function streamThought() {
		active = true;
		for await (const ev of driver.streamAsk(conversation.id, { content: 'think' })) {
			if (ev.event === 'chunk' && ev.chunk.kind === 'reasoning') {
				streamed += ev.chunk.text;
			}
		}
		active = false;
	}
</script>

<Story name="Collapsed" args={{ content: REASONING }} />

<Story
	name="Streaming"
	args={{ content: 'Planning…', active: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const head = canvas.getByText('Thought');
		await expect(head).toBeVisible();
		// Active forces the block open so the reasoning body is visible.
		await expect(canvas.getByText('Planning…')).toBeVisible();
		// A still-streaming block offers no copy affordance yet.
		await expect(canvas.queryByRole('button', { name: 'Copy thought' })).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; max-width: 760px;">
			<ThoughtBlock content={args.content} active={args.active} />
		</div>
	{/snippet}
</Story>
<Story
	name="CollapsesWhenDone"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// While streaming the block is open so the reasoning is visible.
		const body = await waitFor(() => canvas.getByText(/thinking through the domain model/i));
		await expect(body).toBeVisible();
		// Once the stream ends the block folds away: the details is no longer
		// open, so the reasoning body is hidden.
		const details = canvasElement.querySelector('details.thought') as HTMLDetailsElement;
		await waitFor(() => expect(details.open).toBe(false));
		await expect(body).not.toBeVisible();
		// It stays reopenable: clicking the header re-expands the body.
		await canvas.getByText('Thought').click();
		await waitFor(() => expect(details.open).toBe(true));
		await expect(canvas.getByText(/thinking through the domain model/i)).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="padding: 24px; max-width: 760px;">
			<ThoughtBlock content={streamed} {active} />
		</div>
	{/snippet}
</Story>

<Story
	name="CopyThought"
	args={{ content: REASONING }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Headless Chromium may reject clipboard writes; stub the API so the
		// click deterministically reaches the copied state.
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: async () => {} },
			configurable: true
		});
		const details = canvasElement.querySelector('details.thought') as HTMLDetailsElement;
		await expect(details.open).toBe(false);
		const btn = canvas.getByRole('button', { name: 'Copy thought' });
		await userEvent.click(btn);
		// The copy must not toggle the disclosure — the block stays collapsed…
		await expect(details.open).toBe(false);
		// …and the icon flips to the copied state.
		await waitFor(() => expect(btn).toHaveClass('copied'));
		// The header still toggles normally on its own click.
		await canvas.getByText('Thought').click();
		await expect(details.open).toBe(true);
	}}
/>

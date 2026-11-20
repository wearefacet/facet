<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import ChatThread from './ChatThread.svelte';
	import ChatBubble from './ChatBubble.svelte';
	import ChatInput from './ChatInput.svelte';
	import ChatScroll from './ChatScroll.svelte';
	import ChatTurnPanel from './ChatTurnPanel.svelte';
	import {
		MockAssistantDriver,
		applyChunkToParts,
		appendTextPart,
		type AgentPart
	} from '$lib/assistant/index.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ChatThread',
		component: ChatThread,
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	import type { Conversation } from '$lib/assistant/types.js';
	import { onMount } from 'svelte';

	type Turn =
		| { id: number; kind: 'user'; content: string }
		| {
				id: number;
				kind: 'agent';
				parts: AgentPart[];
				streaming: boolean;
		  };

	/** Monotonic counter for stable turn keys. */
	let turnSeq = 0;

	/**
	 * Builds a fresh driver + conversation for each story render. Each story
	 * receives its own driver so they don't cross-contaminate conversation
	 * state — mirroring how the real app issues one `createConversation` per
	 * opened session. Resolves synchronously because the mock is in-memory.
	 */
	function makeDriver(): { driver: MockAssistantDriver; conversation: Conversation } {
		const driver = new MockAssistantDriver();
		const conversation = driver.createConversationSync({});
		return { driver, conversation };
	}

	const INITIAL_USER = 'I want to model shipments in a new `logistics` domain.';

	// ── CopyAnswer story fixtures — a finished turn with thought + trace ────
	const COPY_PROMPT = 'Summarize the shipments rollout.';
	const COPY_THOUGHT =
		'The user asked for a rollout summary; the shipment doctype and its status enum are the pieces worth mentioning.';
	const COPY_ANSWER =
		'Shipments is ready to roll out. Create the doctype, then add the `status` enum and the customer reference.';
	const copyTurnParts: AgentPart[] = [
		{ type: 'reasoning', content: COPY_THOUGHT },
		{
			type: 'tool_call',
			toolCall: {
				name: 'inspect_domain',
				detail: 'inspected domain logistics',
				result: '3 doctypes',
				status: 'ok'
			}
		},
		{ type: 'text', content: COPY_ANSWER }
	];
	const streamingCopyParts: AgentPart[] = [
		{ type: 'text', content: 'Working on the rollout plan…' }
	];
	const { driver: logisticsDriver, conversation: logisticsConv } = makeDriver();

	let logisticsTurns = $state<Turn[]>([{ id: ++turnSeq, kind: 'user', content: INITIAL_USER }]);
	let logisticsBusy = $state(false);

	onMount(() => {
		streamLogistics();
	});

	async function streamLogistics() {
		logisticsBusy = true;
		let parts: AgentPart[] = [];
		let streaming = true;
		const idx = logisticsTurns.length;
		logisticsTurns = [
			...logisticsTurns,
			{ id: ++turnSeq, kind: 'agent', parts: [], streaming: true }
		];

		for await (const ev of logisticsDriver.streamAsk(logisticsConv.id, { content: INITIAL_USER })) {
			if (ev.event === 'chunk') {
				parts = applyChunkToParts(parts, ev.chunk);
			} else if (ev.event === 'done') {
				streaming = false;
			} else if (ev.event === 'error') {
				parts = appendTextPart(parts, `\n\n> Error: ${ev.message}`);
				streaming = false;
			} else if (ev.event === 'cancelled') {
				parts = appendTextPart(parts, '\n\n> Cancelled.');
				streaming = false;
			}
			logisticsTurns = logisticsTurns.map((t, i) =>
				i === idx && t.kind === 'agent' ? { ...t, parts, streaming } : t
			);
		}
		logisticsBusy = false;
	}

	// ── LiveConversation story state ───────────────────────────────────────
	const { driver: liveDriver, conversation: liveConv } = makeDriver();
	let liveTurns = $state<Turn[]>([]);
	let liveBusy = $state(false);

	async function handleLiveSend(text: string) {
		liveTurns = [...liveTurns, { id: ++turnSeq, kind: 'user', content: text }];
		liveBusy = true;

		const agentTurn: Turn = { id: ++turnSeq, kind: 'agent', parts: [], streaming: true };
		liveTurns = [...liveTurns, agentTurn];
		const idx = liveTurns.length - 1;

		let parts: AgentPart[] = [];
		let streaming = true;

		for await (const ev of liveDriver.streamAsk(liveConv.id, { content: text })) {
			if (ev.event === 'chunk') {
				parts = applyChunkToParts(parts, ev.chunk);
			} else if (ev.event === 'done') {
				streaming = false;
			} else if (ev.event === 'error') {
				parts = appendTextPart(parts, `\n\n> Error: ${ev.message}`);
				streaming = false;
			} else if (ev.event === 'cancelled') {
				parts = appendTextPart(parts, '\n\n> Cancelled.');
				streaming = false;
			}
			liveTurns = liveTurns.map((t, i) =>
				i === idx && t.kind === 'agent' ? { ...t, parts, streaming } : t
			);
		}
		liveBusy = false;
	}

	// ── Cancelled story state ─────────────────────────────────────────────────
	const CANCEL_MSG = 'Run a long task, then I will cancel it.';
	const { driver: cancelDriver, conversation: cancelConv } = makeDriver();
	let cancelTurns = $state<Turn[]>([{ id: ++turnSeq, kind: 'user', content: CANCEL_MSG }]);
	let cancelBusy = $state(false);

	onMount(() => {
		streamThenCancel();
	});

	async function streamThenCancel() {
		cancelBusy = true;
		let parts: AgentPart[] = [];
		const agentIdx = cancelTurns.length;
		cancelTurns = [...cancelTurns, { id: ++turnSeq, kind: 'agent', parts: [], streaming: true }];

		for await (const ev of cancelDriver.streamAsk(cancelConv.id, { content: CANCEL_MSG })) {
			if (ev.event === 'meta') {
				// Auto-cancel shortly after the turn starts — gives the viewer time
				// to see the streaming bubble before the kill.
				setTimeout(() => cancelDriver.cancel(ev.turn_token), 250);
			}
			if (ev.event === 'chunk') {
				parts = applyChunkToParts(parts, ev.chunk);
				cancelTurns = cancelTurns.map((t, i) =>
					i === agentIdx && t.kind === 'agent' ? { ...t, parts, streaming: true } : t
				);
			} else if (ev.event === 'cancelled') {
				parts = appendTextPart(parts, '\n\n> Cancelled.');
				cancelTurns = cancelTurns.map((t, i) =>
					i === agentIdx && t.kind === 'agent' ? { ...t, parts, streaming: false } : t
				);
			}
		}
		cancelBusy = false;
	}
</script>

<Story name="Conversation">
	{#snippet template()}
		<div
			style="display: flex; flex-direction: column; height: 80vh; min-height: 500px; max-width: 760px; margin: 0 auto; background: var(--surface);"
		>
			<ChatScroll>
				<div style="padding: 22px;">
					<ChatThread daymark="New domain · logistics">
						{#each logisticsTurns as t (t.id)}
							{#if t.kind === 'user'}
								<ChatBubble role="user" content={t.content} />
							{:else}
								<ChatTurnPanel
									name="Steve"
									tag="schema agent"
									parts={t.parts}
									streaming={t.streaming}
									streamActive={t.streaming}
								/>
							{/if}
						{/each}
					</ChatThread>
				</div>
			</ChatScroll>
			<div style="padding: 12px 22px 16px; border-top: 1px solid var(--border);">
				<ChatInput
					placeholder="Describe a doctype, a field, or a relationship…"
					busy={logisticsBusy}
				/>
			</div>
		</div>
	{/snippet}
</Story>

<Story name="LiveConversation">
	{#snippet template()}
		<div
			style="display: flex; flex-direction: column; height: 80vh; min-height: 500px; max-width: 760px; margin: 0 auto; background: var(--surface);"
		>
			<ChatScroll>
				<div style="padding: 22px;">
					<ChatThread daymark="Try: logistics · fail · cancel">
						{#if liveTurns.length === 0}
							<div style="color: var(--text-3); font-size: 13px; padding: 8px 0;">
								Send a message — try “design a logistics domain”, “make this fail”, or “a long task
								I can cancel”.
							</div>
						{/if}
						{#each liveTurns as t (t.id)}
							{#if t.kind === 'user'}
								<ChatBubble role="user" content={t.content} />
							{:else}
								<ChatTurnPanel
									name="Steve"
									tag="schema agent"
									parts={t.parts}
									streaming={t.streaming}
									streamActive={t.streaming}
								/>
							{/if}
						{/each}
					</ChatThread>
				</div>
			</ChatScroll>
			<div style="padding: 12px 22px 16px; border-top: 1px solid var(--border);">
				<ChatInput
					placeholder="Describe a doctype, a field, or a relationship…"
					busy={liveBusy}
					onsend={handleLiveSend}
				/>
			</div>
		</div>
	{/snippet}
</Story>

<Story name="Cancelled">
	{#snippet template()}
		<div
			style="display: flex; flex-direction: column; height: 80vh; min-height: 500px; max-width: 760px; margin: 0 auto; background: var(--surface);"
		>
			<ChatScroll>
				<div style="padding: 22px;">
					<ChatThread daymark="Cancel flow">
						{#each cancelTurns as t (t.id)}
							{#if t.kind === 'user'}
								<ChatBubble role="user" content={t.content} />
							{:else}
								<ChatTurnPanel
									name="Steve"
									tag="schema agent"
									parts={t.parts}
									streaming={t.streaming}
									streamActive={t.streaming}
								/>
							{/if}
						{/each}
					</ChatThread>
				</div>
			</ChatScroll>
			<div style="padding: 12px 22px 16px; border-top: 1px solid var(--border);">
				<ChatInput placeholder="Agent is thinking…" busy={cancelBusy} />
			</div>
		</div>
	{/snippet}
</Story>

<Story
	name="CopyAnswer"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Headless Chromium may reject clipboard writes; stub the API and record
		// the payload so the assertion can check exactly what was copied.
		const writeText = fn();
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText },
			configurable: true
		});
		// Only the finished turn offers the answer copy; a turn that still
		// streams renders none.
		const btns = canvas.getAllByRole('button', { name: 'Copy answer' });
		await expect(btns).toHaveLength(1);
		const btn = btns[0];
		await userEvent.click(btn);
		// The payload is the answer text only — no reasoning, no tool trace.
		await waitFor(() => expect(writeText).toHaveBeenCalledWith(COPY_ANSWER));
		await waitFor(() => expect(btn).toHaveClass('copied'));
		// The thought block carries its own per-block copy.
		const thoughtBtn = canvas.getByRole('button', { name: 'Copy thought' });
		await userEvent.click(thoughtBtn);
		await waitFor(() => expect(writeText).toHaveBeenLastCalledWith(COPY_THOUGHT));
	}}
>
	{#snippet template()}
		<div style="padding: 22px; max-width: 760px; background: var(--surface);">
			<ChatThread>
				<ChatBubble role="user" content={COPY_PROMPT} />
				<ChatTurnPanel name="Steve" tag="schema agent" parts={copyTurnParts} streaming={false} />
				<ChatTurnPanel
					name="Steve"
					tag="schema agent"
					parts={streamingCopyParts}
					streaming={true}
					streamActive={true}
				/>
			</ChatThread>
		</div>
	{/snippet}
</Story>

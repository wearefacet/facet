<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ChatScroll from './ChatScroll.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ChatScroll',
		component: ChatScroll,
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	import ChatThread from './ChatThread.svelte';
	import ChatBubble from './ChatBubble.svelte';

	// A growing list of messages. Clicking "Append message" adds a new agent
	// bubble. If the user is anchored to the bottom, the view follows; if
	// they've scrolled up, it stays put.
	type Msg = { id: number; role: 'user' | 'agent'; content: string };
	let nextId = 3;
	let messages = $state<Msg[]>([
		{
			id: 1,
			role: 'user',
			content: 'First message — scroll up, then append to see the anchor break.'
		},
		{
			id: 2,
			role: 'agent',
			content:
				'Got it. Try scrolling up a bit, then click **Append message** — the view should *not* jump. Scroll back to the bottom and click again — it should follow.'
		}
	]);

	const SAMPLE = [
		'Adding a new turn to the conversation. The auto-scroll should follow if you are at the bottom.',
		'Another turn. Notice the view stays put when you are scrolled up.',
		'A longer message with some `inline code` and **bold** to grow the bubble height and exercise the `MutationObserver`.'
	];

	function append() {
		const content = SAMPLE[messages.length % SAMPLE.length];
		messages = [...messages, { id: nextId++, role: 'agent', content }];
	}
</script>

<Story name="AutoStickToBottom">
	{#snippet template()}
		<div
			style="display: flex; flex-direction: column; height: 80vh; min-height: 500px; max-width: 760px; margin: 0 auto; background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg); overflow: hidden;"
		>
			<ChatScroll>
				<div style="padding: 22px;">
					<ChatThread daymark="Auto-scroll demo">
						{#each messages as m (m.id)}
							<ChatBubble role={m.role} content={m.content} />
						{/each}
					</ChatThread>
				</div>
			</ChatScroll>
			<div
				style="padding: 12px 22px 16px; border-top: 1px solid var(--border); display: flex; gap: 8px; align-items: center;"
			>
				<button
					type="button"
					onclick={append}
					style="font: inherit; font-weight: 600; font-size: 13px; padding: 8px 13px; border: 1px solid var(--border); border-radius: var(--r); background: var(--accent); color: var(--on-accent); cursor: pointer;"
				>
					Append message
				</button>
				<span style="font-family: var(--font-mono); font-size: 11px; color: var(--text-3);">
					scroll up to break the anchor · scroll down to restore it
				</span>
			</div>
		</div>
	{/snippet}
</Story>

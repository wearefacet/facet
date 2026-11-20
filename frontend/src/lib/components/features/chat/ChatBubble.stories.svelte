<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ChatBubble from './ChatBubble.svelte';
	import { MockAssistantDriver } from '$lib/assistant/index.js';
	import type { Conversation } from '$lib/assistant/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ChatBubble',
		component: ChatBubble,
		tags: ['autodocs'],
		argTypes: {
			role: {
				control: 'select',
				options: ['user', 'agent']
			}
		}
	});
</script>

<script lang="ts">
	import { onMount } from 'svelte';

	// Drive streaming through the mock driver: same code path stories use,
	// instead of an inline setInterval. One-shot on mount.
	const driver = new MockAssistantDriver();
	const conversation: Conversation = driver.createConversationSync({});

	let streamContent = $state('');
	let streaming = $state(true);

	onMount(() => {
		streamBubble();
	});

	async function streamBubble() {
		const text = 'Design a logistics domain for shipments.';
		for await (const ev of driver.streamAsk(conversation.id, { content: text })) {
			if (ev.event === 'chunk') {
				if (ev.chunk.kind === 'content') {
					streamContent += ev.chunk.text;
				}
			} else if (ev.event === 'done') {
				streaming = false;
			}
		}
	}
</script>

<Story
	name="User"
	args={{
		role: 'user',
		content:
			'I want to model shipments in a new `logistics` domain. A shipment has an origin and destination address, moves through a status, carries a list of packages, and is billed to a customer from CRM.'
	}}
/>

<Story
	name="Agent"
	args={{
		role: 'agent',
		name: 'Steve',
		tag: 'schema agent',
		content:
			"I'll start a `logistics` domain with `Shipment` as an aggregate root. The two addresses fit as embedded objects, status maps to an enum, and the customer becomes a cross-domain reference into `crm.Customer`.\n\nFirst draft:\n\n- `reference_no` — booking reference\n- `status` — enum\n- `customer_id` — reference to `crm.Customer`"
	}}
/>

<Story name="AgentStreaming">
	{#snippet template()}
		<div style="padding: 24px; max-width: 760px;">
			<ChatBubble
				role="agent"
				name="Steve"
				tag="schema agent"
				content={streamContent}
				{streaming}
			/>
		</div>
	{/snippet}
</Story>

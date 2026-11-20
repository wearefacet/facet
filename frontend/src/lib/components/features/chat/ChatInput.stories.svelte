<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import ChatInput from './ChatInput.svelte';
	import { Paperclip } from '@lucide/svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ChatInput',
		component: ChatInput,
		tags: ['autodocs'],
		args: {
			onsend: fn(),
			onstop: fn()
		}
	});
</script>

<script lang="ts">
	// Live two-way bound story: shows the value updating as you type, and
	// logs sends to the Actions panel via the `onsend` fn from args.
	let liveValue = $state('');
</script>

<Story name="Default" args={{ placeholder: 'Describe a doctype, a field, or a relationship…' }} />

<Story name="Prefilled" args={{ value: 'Promote packages to a child collection.' }} />

<Story name="Disabled" args={{ disabled: true, placeholder: 'Agent is thinking…' }} />

<Story name="Busy">
	{#snippet template(args)}
		<div style="padding: 24px; max-width: 760px;">
			<ChatInput busy placeholder="Agent is thinking…" onstop={args.onstop} />
		</div>
	{/snippet}
</Story>

<Story name="WithFooterRow">
	{#snippet template(args)}
		<div style="padding: 24px; max-width: 760px;">
			<ChatInput onsend={args.onsend} placeholder={args.placeholder}>
				<button class="ctx-attach" type="button" aria-label="Attach context">
					<Paperclip size={15} />
				</button>
				<span class="ctx-model">Qwen3.6-35B · local</span>
			</ChatInput>
		</div>
	{/snippet}
</Story>

<Story name="Live">
	{#snippet template(args)}
		<div style="padding: 24px; max-width: 760px; display: flex; flex-direction: column; gap: 12px;">
			<ChatInput
				bind:value={liveValue}
				onsend={args.onsend}
				placeholder="Type and press Ctrl+Enter to send…"
			/>
			<div style="font-family: var(--font-mono); font-size: 11.5px; color: var(--text-3);">
				current value: {liveValue || '(empty)'}
			</div>
		</div>
	{/snippet}
</Story>

<style>
	.ctx-attach {
		width: 30px;
		height: 30px;
		border-radius: 8px;
		display: grid;
		place-items: center;
		color: var(--text-2);
		background: none;
		border: none;
		cursor: pointer;
	}
	.ctx-attach:hover {
		background: var(--sunken);
		color: var(--text);
	}
	.ctx-model {
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
		padding: 2px 4px;
	}
</style>

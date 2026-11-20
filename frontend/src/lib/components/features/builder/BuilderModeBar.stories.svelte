<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn } from 'storybook/test';
	import BuilderModeBar from './BuilderModeBar.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Builder/BuilderModeBar',
		component: BuilderModeBar,
		tags: ['autodocs'],
		argTypes: {
			message: { control: 'text' },
			exitLabel: { control: 'text' },
			onexit: { action: 'exit' }
		},
		args: {
			message: 'Builder mode — configuration is live',
			exitLabel: 'Exit',
			onexit: fn(),
			onpublish: fn()
		}
	});
</script>

{#snippet chrome(
	args: { message?: string; exitLabel?: string; onexit?: () => void },
	trailing?: import('svelte').Snippet
)}
	<div class="frame">
		<BuilderModeBar message={args.message} exitLabel={args.exitLabel} onexit={args.onexit}>
			{@render trailing?.()}
		</BuilderModeBar>
		<div class="body">
			<p>
				Workspace preview — the builder bar replaces the app top bar while builder mode is active,
				with the same height, surface, and border.
			</p>
		</div>
	</div>
{/snippet}

<Story name="Default">
	{#snippet template(args)}
		{@render chrome(args, undefined)}
	{/snippet}
</Story>

<Story name="Custom Message" args={{ message: 'Editing doctype: invoice — unsaved changes' }}>
	{#snippet template(args)}
		{@render chrome(args, undefined)}
	{/snippet}
</Story>

<Story name="With Save Indicator">
	{#snippet template(args)}
		{@render chrome(args, saveIndicator)}
	{/snippet}
</Story>

{#snippet saveIndicator()}
	<span class="save">Saved 2m ago</span>
{/snippet}

<Story name="Bare">
	{#snippet template(args)}
		<BuilderModeBar message={args.message} exitLabel={args.exitLabel} onexit={args.onexit} />
	{/snippet}
</Story>

<Story
	name="DraftCanPublish"
	args={{ isDraft: true, canPublish: true, checkIssueCount: 0 }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const publish = canvas.getByRole('button', { name: /Publish/ });
		await expect(publish).toBeEnabled();
		await userEvent.click(publish);
		await expect(args.onpublish).toHaveBeenCalledOnce();
	}}
/>

<style>
	.frame {
		display: flex;
		flex-direction: column;
		width: 100%;
		min-height: 320px;
		background: var(--ground);
		overflow: hidden;
	}

	.frame .body {
		padding: 24px 18px;
		color: var(--text-2);
		font-size: 13px;
	}

	.frame :global(.save) {
		color: var(--accent-ink);
		font-size: 11.5px;
		font-weight: 600;
		font-family: var(--font-mono);
		white-space: nowrap;
	}
</style>

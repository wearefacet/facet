<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import AssistantHost from './AssistantHost.svelte';
	import { initAssistantOpen, setAssistantOpen } from '$lib/assistantOpen.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/AssistantHost',
		component: AssistantHost,
		tags: ['autodocs'],
		args: {
			surface: 'builder',
			draftDomain: '_abc',
			accountId: '01JACC1'
		}
	});

	// The host gates on the module-level open flag; reset it around each story.
	function closeAssistant(): void {
		setAssistantOpen(false);
	}

	// Hydrate once so the module flag starts from the storage default (closed)
	// rather than whatever a previous file left behind.
	initAssistantOpen();
	closeAssistant();
</script>

<!-- The open-state story mounts the full assistant window (chat driver +
     conversation fetch), which needs a live backend — the host's own
     contract is the gating, covered here; the window itself is covered by
     the ChatPanel / AssistantWindow surfaces. -->

<Story
	name="ClosedMountsNothing"
	args={{ surface: 'builder', draftDomain: '_abc', accountId: '01JACC1' }}
	play={async ({ canvasElement }) => {
		setAssistantOpen(false);
		const canvas = within(canvasElement);
		await expect(canvas.queryByText('Assistant')).toBeNull();
	}}
/>

<Story
	name="NoSurfaceMountsNothing"
	args={{ surface: null, draftDomain: '_abc', accountId: '01JACC1' }}
	play={async ({ canvasElement }) => {
		// Even with the flag open, a null surface (Configure, consent,
		// unauthenticated) mounts no window.
		setAssistantOpen(true);
		const canvas = within(canvasElement);
		await expect(canvas.queryByText('Assistant')).toBeNull();
		closeAssistant();
	}}
/>

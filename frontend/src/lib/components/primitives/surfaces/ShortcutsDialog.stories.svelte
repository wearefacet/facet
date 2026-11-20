<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ShortcutsDialog from './ShortcutsDialog.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/ShortcutsDialog',
		component: ShortcutsDialog
	});
</script>

<script lang="ts">
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import {
		getShortcutsHelpOpen,
		modKeyLabel,
		registerGlobalShortcuts,
		setShortcutsHelpOpen
	} from '$lib/shortcuts.svelte';

	// Bits UI `Dialog.Portal` mounts content into `document.body`, so the
	// play functions query `within(document.body)`. The dialog opens through
	// the help-open store (the app opens it with `?`); each play resets the
	// store and unregisters its seeded entries in `finally`, so the shared
	// isolate:false page never inherits registry state.
</script>

<Story
	name="ListsActiveShortcutsByGroup"
	play={async () => {
		const body = within(document.body);
		const unregister = registerGlobalShortcuts([
			{
				id: 'story.assistant',
				keys: 'Mod+I',
				label: 'Toggle assistant',
				group: 'general',
				handler: () => false
			},
			{
				id: 'story.sidebar',
				keys: 'Mod+\\',
				label: 'Collapse or expand the sidebar',
				group: 'general',
				handler: () => false
			},
			{
				id: 'story.new',
				keys: 'C',
				label: 'New record',
				group: 'list',
				handler: () => false
			},
			{
				id: 'story.save',
				keys: 'Mod+S',
				label: 'Save the form',
				group: 'document',
				handler: () => false
			}
		]);
		try {
			setShortcutsHelpOpen(true);

			await waitFor(() => {
				expect(body.getByRole('heading', { name: 'Keyboard shortcuts' })).toBeVisible();
			});

			// Groups render in the fixed order; empty groups stay hidden.
			await expect(body.getByText('General')).toBeVisible();
			await expect(body.getByText('List')).toBeVisible();
			await expect(body.getByText('Document')).toBeVisible();

			// Every registered entry shows under its group label.
			await expect(body.getByText('Toggle assistant')).toBeVisible();
			await expect(body.getByText('New record')).toBeVisible();
			await expect(body.getByText('Save the form')).toBeVisible();

			// Key hints render one <kbd> per token, with the platform mod label.
			expect(body.getAllByText(modKeyLabel()).length).toBeGreaterThanOrEqual(3);
			await expect(body.getByText('C')).toBeVisible();
			await expect(body.getByText('I')).toBeVisible();
			await expect(body.getByText('S')).toBeVisible();
		} finally {
			setShortcutsHelpOpen(false);
			unregister();
		}
	}}
>
	{#snippet template()}
		<ShortcutsDialog />
	{/snippet}
</Story>

<Story
	name="ClosesThroughBitsUiAndResetsStore"
	play={async () => {
		const body = within(document.body);
		setShortcutsHelpOpen(true);
		try {
			await waitFor(() => {
				expect(body.getByRole('heading', { name: 'Keyboard shortcuts' })).toBeVisible();
			});

			// The store starts open; the Bits UI close must write back false so
			// the next `?` press opens the dialog again.
			await expect(getShortcutsHelpOpen()).toBe(true);
			await userEvent.click(body.getByRole('button', { name: 'Close shortcuts' }));
			await waitFor(() => {
				expect(getShortcutsHelpOpen()).toBe(false);
			});
		} finally {
			setShortcutsHelpOpen(false);
		}
	}}
>
	{#snippet template()}
		<ShortcutsDialog />
	{/snippet}
</Story>

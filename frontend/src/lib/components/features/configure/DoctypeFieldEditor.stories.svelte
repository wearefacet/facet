<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import DoctypeFieldEditor from './DoctypeFieldEditor.svelte';
	import type { FieldDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/DoctypeFieldEditor',
		component: DoctypeFieldEditor,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/** Draft domain passed as the editor's qualification scope. */
	const DRAFT_DOMAIN = '_draft01';

	/** A reference field whose target the play functions type into. */
	function initialField(): FieldDef {
		return { key: 'account', type: 'reference', title: 'Account' };
	}

	/**
	 * Session-local clone of the story's field object. The component mutates
	 * `field` in place, and the write must not go through the Storybook args
	 * proxy (workflow.md → CSF indexer and play-context args). The clone is
	 * built in the template, so each render (retry included) starts pristine.
	 */
	function sessionField(field: FieldDef | undefined): FieldDef | undefined {
		return field ? { ...field } : undefined;
	}
</script>

<!--
	The stored target is asserted through the input's DOM value: the commit
	handler writes the qualified value straight into the element, and object
	mutations through `args` are invisible to the play context.
-->

<Story
	name="QualifiesBareReferenceTarget"
	args={{ field: initialField(), domain: DRAFT_DOMAIN }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Target doctype') as HTMLInputElement;
		await userEvent.type(input, 'Contact');
		// The commit (blur) qualifies the bare target into the
		// `domain.Target` form the backend Check requires.
		await userEvent.tab();
		await waitFor(() => expect(input).toHaveValue('_draft01.Contact'));
	}}
>
	{#snippet template(args)}
		<DoctypeFieldEditor field={sessionField(args.field)} domain={args.domain} />
	{/snippet}
</Story>

<Story
	name="PassesQualifiedTargetThrough"
	args={{ field: initialField(), domain: DRAFT_DOMAIN }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Target doctype') as HTMLInputElement;
		await userEvent.type(input, 'iam.Account');
		await userEvent.tab();
		// A target that already carries a domain stays untouched.
		await expect(input).toHaveValue('iam.Account');
	}}
>
	{#snippet template(args)}
		<DoctypeFieldEditor field={sessionField(args.field)} domain={args.domain} />
	{/snippet}
</Story>

<!-- The unique toggle sits next to Required and flips the flag on the
	definition. Secret fields reject unique server-side, so the toggle
	never renders for one. -->
<Story
	name="UniqueToggleFlips"
	args={{ field: { key: 'email', type: 'string', title: 'Email' }, domain: DRAFT_DOMAIN }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const unique = canvas.getByRole('switch', { name: 'Unique' });
		await expect(unique).toHaveAttribute('aria-checked', 'false');
		await userEvent.click(unique);
		await expect(unique).toHaveAttribute('aria-checked', 'true');
	}}
>
	{#snippet template(args)}
		<DoctypeFieldEditor field={sessionField(args.field)} domain={args.domain} />
	{/snippet}
</Story>

<Story
	name="UniqueToggleHiddenForSecret"
	args={{ field: { key: 'token', type: 'secret', title: 'Token' }, domain: DRAFT_DOMAIN }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		expect(canvas.queryByRole('switch', { name: 'Unique' })).toBeNull();
		// Required stays available on the same row.
		await expect(canvas.getByRole('switch', { name: 'Required' })).toBeVisible();
	}}
>
	{#snippet template(args)}
		<DoctypeFieldEditor field={sessionField(args.field)} domain={args.domain} />
	{/snippet}
</Story>

<!-- Renaming a key onto a sibling's key must not write the duplicate into
	the shared definition — the keyed each in DoctypeFieldList would throw
	`each_key_duplicate`. The component refuses the write: the input keeps
	the typed text and the inline duplicate error names the collision. The
	definition-level effect (the definition keeps the last legal prefix and
	the list stays intact) is pinned in DoctypeEditor's
	"Deal — duplicate key rename is blocked" story, where the field is the
	editor's real `$state` proxy. -->
<Story
	name="DuplicateKeyRenameIsBlocked"
	args={{
		field: { key: 'amount', type: 'money', title: 'Amount' },
		allFields: [
			{ key: 'amount', type: 'money', title: 'Amount' },
			{ key: 'stage', type: 'reference', title: 'Stage' }
		]
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const keyInput = canvas.getByLabelText('Key') as HTMLInputElement;

		// Type the sibling's key. The final keystroke collides: the input
		// keeps the typed text and the error shows.
		await userEvent.clear(keyInput);
		await userEvent.type(keyInput, 'stage');
		await expect(keyInput).toHaveValue('stage');
		await expect(canvas.getByText('Key "stage" already exists')).toBeVisible();

		// Typing past the collision writes again and clears the error.
		await userEvent.type(keyInput, '_v2');
		await expect(keyInput).toHaveValue('stage_v2');
		await expect(canvas.queryByText(/already exists/)).toBeNull();
	}}
>
	{#snippet template(args)}
		<DoctypeFieldEditor
			field={sessionField(args.field)}
			allFields={args.allFields}
			domain={DRAFT_DOMAIN}
		/>
	{/snippet}
</Story>

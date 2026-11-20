<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DoctypeViewsTab from './DoctypeViewsTab.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { TemplateNode } from '$lib/template-types';
	import { type ViewKind } from '$lib/doctype/previewDocument.js';
	import { setPermissions } from '$lib/permissions.svelte';

	// The admin wildcard hydrates the permission store so the Edit toggle
	// renders — it is `can('core.DocumentView', …)`-gated, and read-only is
	// the safe default. The gated case is covered by the story that clears
	// the manifest inside its play.
	setPermissions({ '*.*': ['*'] });

	// The mock driver satisfies `DoctypeDefinitionRegistry` natively — the
	// same substitution the `DoctypeEditor` stories use.
	const driver = createMockDriver();

	/** Resolve + parse a doctype definition by qualified name from the mock driver. */
	function defFor(qualifiedName: string): DoctypeDef {
		const raw = driver.doctypeDefinitions.get(qualifiedName);
		if (!raw) throw new Error(`mock doctype ${qualifiedName} not registered`);
		return parseDoctypeDef(raw) as DoctypeDef;
	}

	const employeeDef = defFor('hr.Employee');
	const dealDef = defFor('crm.Deal');

	/** One stored `view` kind — every other kind shows the fallback badge. */
	const employeeViews: Partial<Record<ViewKind, TemplateNode | null>> = {
		view: {
			type: 'col',
			children: [{ type: 'field', label: 'Department', value: '$department' }]
		}
	};

	/** No stored views at all — the empty state with the authoring note. */
	const emptyViews: Partial<Record<ViewKind, TemplateNode | null>> = {};

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/DoctypeViewsTab',
		component: DoctypeViewsTab,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): the embedded
		// DoctypeViewPreview carries the known violations. Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { expect, fn, userEvent, within } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
</script>

<!--
	The tab previews a fallback template when no view is stored, and says so:
	the empty state names the Edit mode as the authoring path. The Edit toggle
	is permission-gated (the admin wildcard is set at module load).
-->
<Story
	name="NoStoredViews"
	args={{ def: dealDef, views: emptyViews, selectedViewKind: 'view', onselect: fn() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The empty state explains the fallback and points at Edit.
		await expect(canvas.getByText(m.configure_doctypes_views_empty_hint())).toBeVisible();
		await expect(canvas.queryByText(/preview only/)).toBeNull();
		await expect(canvas.queryByText(/REST API/)).toBeNull();
		// The Edit affordance is present for a writer and swaps the pane for
		// the JSON textarea.
		const edit = canvas.getByRole('button', { name: m.configure_doctypes_views_edit_button() });
		await expect(edit).toBeVisible();
		await edit.click();
		const textarea = await canvas.findByLabelText(
			m.configure_doctypes_views_json_label({ kind: 'view' })
		);
		await expect(textarea).toBeVisible();
		// The draft starts from the definition-generated fallback template.
		await expect((textarea as HTMLTextAreaElement).value).toContain('"type": "col"');
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DoctypeViewsTab
				def={args.def}
				views={args.views}
				registry={driver}
				qualifiedName="crm.Deal"
				selectedViewKind={args.selectedViewKind}
				onselect={args.onselect}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="StoredView"
	args={{ def: employeeDef, views: employeeViews, selectedViewKind: 'view', onselect: fn() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The stored `view` kind shows the defined badge; the four kinds
		// without a stored template show the fallback badge (the preview
		// header repeats the badge of the selected kind).
		await expect(canvas.getAllByText('defined').length).toBeGreaterThanOrEqual(1);
		await expect(canvas.getAllByText('fallback').length).toBeGreaterThanOrEqual(4);
		// The authoring note belongs to the empty state only.
		await expect(canvas.queryByText(m.configure_doctypes_views_empty_hint())).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DoctypeViewsTab
				def={args.def}
				views={args.views}
				registry={driver}
				qualifiedName="hr.Employee"
				selectedViewKind={args.selectedViewKind}
				onselect={args.onselect}
			/>
		</div>
	{/snippet}
</Story>

<!--
	Invalid JSON: Save runs the local validation only — an inline error
	shows, and the injected write seam is never called.
-->
<Story
	name="InvalidJsonShowsInlineError"
	args={{
		def: dealDef,
		views: emptyViews,
		selectedViewKind: 'view',
		onselect: fn(),
		saveView: fn(async () => undefined)
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await canvas.getByRole('button', { name: m.configure_doctypes_views_edit_button() }).click();
		const textarea = await canvas.findByLabelText(
			m.configure_doctypes_views_json_label({ kind: 'view' })
		);
		await expect(textarea).toBeVisible();
		// Break the JSON, then Save.
		await userEvent.clear(textarea);
		await userEvent.type(textarea, '{{ "type": ');
		await canvas.getByRole('button', { name: m.common_save() }).click();
		const error = await canvas.findByRole('alert');
		await expect(error.textContent ?? '').toContain('not valid JSON');
		await expect(args.saveView).not.toHaveBeenCalled();
		// The pane stays in Edit mode so the user can fix the JSON.
		await expect(textarea).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DoctypeViewsTab
				def={args.def}
				views={args.views}
				registry={driver}
				qualifiedName="crm.Deal"
				selectedViewKind={args.selectedViewKind}
				onselect={args.onselect}
				saveView={args.saveView}
			/>
		</div>
	{/snippet}
</Story>

<!--
	Valid JSON: Save reaches the injected write seam with the parsed template
	and returns to Display — no network in storybook. The post-save maps go
	back to the parent through `onsaved`, so its Views badge can follow.
-->
<Story
	name="SaveCreatesTheView"
	args={{
		def: dealDef,
		views: emptyViews,
		selectedViewKind: 'view',
		onselect: fn(),
		onsaved: fn(),
		saveView: fn(async () => 'crm.Deal.document_view.view')
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await canvas.getByRole('button', { name: m.configure_doctypes_views_edit_button() }).click();
		const textarea = await canvas.findByLabelText(
			m.configure_doctypes_views_json_label({ kind: 'view' })
		);
		await canvas.getByRole('button', { name: m.common_save() }).click();
		await expect(args.saveView).toHaveBeenCalledTimes(1);
		const [parent, kind, template, id] = (args.saveView as ReturnType<typeof fn>).mock.calls[0];
		await expect(parent).toBe('crm.Deal');
		await expect(kind).toBe('view');
		await expect(template).toEqual(JSON.parse((textarea as HTMLTextAreaElement).value));
		// No stored child id — the save is a create.
		await expect(id).toBeUndefined();
		// The parent gets the new maps: the kind now holds a template and the
		// created child id, so a badge derived from them counts one view.
		await expect(args.onsaved).toHaveBeenCalledTimes(1);
		const [savedViews, savedIds] = (args.onsaved as ReturnType<typeof fn>).mock.calls[0];
		await expect(savedViews['view']).toEqual(JSON.parse((textarea as HTMLTextAreaElement).value));
		await expect(savedIds['view']).toBe('crm.Deal.document_view.view');
		// Back to the preview: the toggle shows Display pressed again.
		await expect(
			canvas.getByRole('button', { name: m.configure_doctypes_views_display_button() })
		).toHaveAttribute('aria-pressed', 'true');
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DoctypeViewsTab
				def={args.def}
				views={args.views}
				registry={driver}
				qualifiedName="crm.Deal"
				selectedViewKind={args.selectedViewKind}
				onselect={args.onselect}
				onsaved={args.onsaved}
				saveView={args.saveView}
			/>
		</div>
	{/snippet}
</Story>

<!--
	Read-only caller (a published domain in the Configure shell): the preview
	renders but the Edit toggle is absent — and the empty-state note does not
	point at it.
-->
<Story
	name="ReadOnlyHidesTheEditor"
	args={{
		def: dealDef,
		views: emptyViews,
		readonly: true,
		selectedViewKind: 'view',
		onselect: fn()
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(
			canvas.queryByRole('button', { name: m.configure_doctypes_views_edit_button() })
		).toBeNull();
		// No Edit control on screen, so the note does not name it.
		await expect(canvas.getByText(m.configure_doctypes_views_empty_hint_readonly())).toBeVisible();
		await expect(canvas.queryByText(m.configure_doctypes_views_empty_hint())).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DoctypeViewsTab
				def={args.def}
				views={args.views}
				registry={driver}
				qualifiedName="crm.Deal"
				readonly={args.readonly}
				selectedViewKind={args.selectedViewKind}
				onselect={args.onselect}
			/>
		</div>
	{/snippet}
</Story>

<!--
	A second save of a just-created kind PATCHes the stored child instead of
	creating a duplicate: the write seam reports the new child id, and the tab
	keeps it.
-->
<Story
	name="SecondSavePatchesTheCreatedView"
	args={{
		def: dealDef,
		views: emptyViews,
		selectedViewKind: 'view',
		onselect: fn(),
		saveView: fn(async () => 'crm.Deal.document_view.view')
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const editButton = () =>
			canvas.getByRole('button', { name: m.configure_doctypes_views_edit_button() });

		await editButton().click();
		await canvas.getByRole('button', { name: m.common_save() }).click();
		await expect(args.saveView).toHaveBeenCalledTimes(1);

		// Second round: the stored id now rides the seam as the fourth argument.
		await editButton().click();
		await canvas.getByRole('button', { name: m.common_save() }).click();
		await expect(args.saveView).toHaveBeenCalledTimes(2);
		const calls = (args.saveView as ReturnType<typeof fn>).mock.calls;
		await expect(calls[0][3]).toBeUndefined();
		await expect(calls[1][3]).toBe('crm.Deal.document_view.view');
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DoctypeViewsTab
				def={args.def}
				views={args.views}
				registry={driver}
				qualifiedName="crm.Deal"
				selectedViewKind={args.selectedViewKind}
				onselect={args.onselect}
				saveView={args.saveView}
			/>
		</div>
	{/snippet}
</Story>

<style>
	/* The tab fills its grid with `height: 100%` — give the frame a real
	   height or the fullscreen story layout collapses it to zero. */
	.dvt-story-frame {
		height: 460px;
		padding: 12px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		overflow: hidden;
	}
</style>

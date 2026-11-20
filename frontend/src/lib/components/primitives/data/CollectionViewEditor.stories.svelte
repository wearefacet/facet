<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import CollectionViewEditor from './CollectionViewEditor.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { parseDoctypeDef } from '$lib/doctype/types.js';

	// A single mock driver seeded with all fixtures. CollectionView children
	// are created against the `crm.Deal` parent (auto-seeded as a core.DocType
	// projection with id "crm.Deal" by `seedMockData`).
	const driver = createMockDriver();
	const dealDef = parseDoctypeDef(driver.getDoctypeDefinition('crm.Deal')!);

	/** Unrestricted creator — wildcard, so General is available. */
	const adminManifest = { '*.*': ['*'] };
	/**
	 * A `$mine`-scoped creator: `create`/`update` are present but scoped, so
	 * `canScope('core.CollectionView','create')` is `['mine']` (personal only)
	 * and the General radio is hidden by the `<Can scope="unrestricted">` gate.
	 */
	const scopedManifest = { 'core.CollectionView': ['read', 'create', 'update'] };
	const scopedScopes = {
		'core.CollectionView': { create: ['mine'], update: ['mine'], read: ['mine', 'general'] }
	};

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/CollectionViewEditor',
		component: CollectionViewEditor,
		tags: ['autodocs'],
		args: {
			driver,
			doctype: dealDef,
			parentDocId: 'crm.Deal',
			viewerId: 'iam.Account.viewer'
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within, fireEvent, userEvent, waitFor } from 'storybook/test';

	// Local open state so the "Cancel" story can unmount the editor on close.
	let open = $state(true);
</script>

<!--
	The editor is a modal; each story mounts it already-open. A wrapping
	`<CanFixture>` sets the permission + scope stores so `<Can>` inside the
	editor (General radio, etc.) renders with a deterministic RBAC state.

	The editor renders through a Bits UI `Dialog.Portal`, so the play
	functions query `within(document.body)` — not the canvas root.
-->

<Story
	name="CreateAdmin"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		// Picker step: Table is pre-selected; Calendar (crm.Deal has date
		// fields) and Kanban are enabled; Grid is shown as "soon".
		await expect(canvas.getByRole('heading', { name: 'New view' })).toBeVisible();
		await expect(canvas.getByText('Rows and sortable columns')).toBeVisible();
		await expect(canvas.getByText('Date-based grid')).toBeVisible();
		await expect(canvas.getByText('Cards grouped into lanes')).toBeVisible();
		// Grid is the only disabled forward signal now.
		await expect(canvas.getAllByText('Soon').length).toBe(1);
		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);
		// Config step: an unrestricted creator can choose General.
		await expect(canvas.getByText('General')).toBeVisible();
		await expect(canvas.getByText('Personal')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 600px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CreateCalendar"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		// Select the Calendar surface in the picker.
		await fireEvent.click(canvas.getByRole('button', { name: /Calendar/ }));
		await sleep(20);
		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);
		// Config step shows calendar fields, not the column builder.
		await expect(canvas.getByText('Date field')).toBeVisible();
		await expect(canvas.queryByText('Columns')).toBeNull();
		// An untouched dialog opens without errors — the required hints wait
		// for the first blur (the save button stays disabled regardless).
		await expect(canvas.queryByText('Name is required')).toBeNull();
		await expect(canvas.queryByText('Choose a date field')).toBeNull();
		const createBtn = canvas.getByRole('button', { name: 'Create view' });
		await expect(createBtn).toBeDisabled();
		// Leaving the empty name field for the date picker reveals its error;
		// leaving the date picker without a choice reveals its own.
		await userEvent.click(canvas.getByRole('textbox', { name: /Name/ }));
		await userEvent.click(canvas.getByRole('combobox', { name: 'Date field' }));
		await sleep(20);
		await expect(canvas.getByText('Name is required')).toBeVisible();
		await userEvent.click(canvas.getByRole('textbox', { name: /Name/ }));
		await sleep(10);
		await expect(canvas.getByText('Choose a date field')).toBeVisible();
		// Choose the discriminator via the combobox. The dropdown portals to
		// document.body, so search there for the option. A dropdown closed
		// without a selection stays mounted briefly, so pick from
		// getAllByRole — see the custom-lane story below.
		await userEvent.click(canvas.getByRole('combobox', { name: 'Date field' }));
		await sleep(20);
		const body = within(document.body);
		await userEvent.click(body.getAllByRole('option', { name: /Expected Close Date/ })[0]);
		await sleep(20);
		await userEvent.type(canvas.getByRole('textbox', { name: /Name/ }), 'Timeline');
		await sleep(10);
		// Filling both fields clears the errors again.
		await expect(canvas.queryByText('Name is required')).toBeNull();
		await expect(canvas.queryByText('Choose a date field')).toBeNull();
		await fireEvent.click(canvas.getByRole('button', { name: 'Create view' }));
		await sleep(40);

		// A calendar CollectionView child was created with the expected config.
		const after = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });
		const created = after.data
			.map((d) => d.data)
			.find((v) => (v as { name?: string }).name === 'Timeline') as
			| { surface?: string; config?: { calendar?: { discriminator?: string } } }
			| undefined;
		expect(created).toBeTruthy();
		expect(created?.surface).toBe('calendar');
		expect(created?.config?.calendar?.discriminator).toBe('expected_close_date');
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 700px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CreateKanbanValues"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		// Select the Kanban surface in the picker.
		await fireEvent.click(canvas.getByRole('button', { name: /Kanban/ }));
		await sleep(20);
		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);
		// Config step shows the kanban form, not the column builder.
		await expect(canvas.getByText('Board mode')).toBeVisible();
		await expect(canvas.queryByText('Columns')).toBeNull();
		// An untouched dialog opens without errors — the required hints wait
		// for the first blur (the save button stays disabled regardless).
		await expect(canvas.queryByText('Name is required')).toBeNull();
		await expect(canvas.queryByText('Choose a field to group by')).toBeNull();
		const createBtn = canvas.getByRole('button', { name: 'Create view' });
		await expect(createBtn).toBeDisabled();
		// Leaving the group-by picker without a choice reveals its error:
		// open the dropdown, then click the name field — the outside click
		// closes the dropdown and blurs the picker.
		await userEvent.click(canvas.getByRole('combobox', { name: 'Group by' }));
		await sleep(20);
		await userEvent.click(canvas.getByRole('textbox', { name: /Name/ }));
		await sleep(10);
		await expect(canvas.getByText('Choose a field to group by')).toBeVisible();
		// Choose the group-by field via the combobox (dropdown portals to
		// document.body). A dropdown closed without a selection stays mounted
		// briefly, so pick from getAllByRole — see the custom-lane story.
		await userEvent.click(canvas.getByRole('combobox', { name: 'Group by' }));
		await sleep(20);
		const body = within(document.body);
		await userEvent.click(body.getAllByRole('option', { name: /Status/ })[0]);
		await sleep(20);
		// Picking a field clears the error again.
		await expect(canvas.queryByText('Choose a field to group by')).toBeNull();
		// The name is required too — fill it, then the save button enables.
		await userEvent.type(canvas.getByRole('textbox', { name: /Name/ }), 'Pipeline');
		await sleep(10);
		await expect(createBtn).toBeEnabled();
		await fireEvent.click(createBtn);
		await sleep(40);

		// A kanban CollectionView child was created with the values config.
		const after = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });
		const created = after.data
			.map((d) => d.data)
			.find((v) => (v as { name?: string }).name === 'Pipeline') as
			| { surface?: string; config?: { kanban?: Record<string, unknown> } }
			| undefined;
		expect(created).toBeTruthy();
		expect(created?.surface).toBe('kanban');
		expect(created?.config?.kanban?.mode).toBe('values');
		expect(created?.config?.kanban?.group_by).toBe('status');
		expect(created?.config?.kanban?.page_size).toBe(25);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 700px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CreateKanbanCustomValidated"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		await fireEvent.click(canvas.getByRole('button', { name: /Kanban/ }));
		await sleep(20);
		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);
		// Switch to the custom-lane mode.
		await fireEvent.click(canvas.getByRole('radio', { name: /Custom lanes/ }));
		await sleep(20);
		// No lane yet — save is blocked and the lanes error shows.
		const createBtn = canvas.getByRole('button', { name: 'Create view' });
		await expect(createBtn).toBeDisabled();
		await expect(canvas.getByText('Add at least one lane')).toBeVisible();
		// Add an empty lane: the label error surfaces first (one error per
		// lane, label before filter).
		await fireEvent.click(canvas.getByRole('button', { name: 'Add lane' }));
		await sleep(20);
		await expect(createBtn).toBeDisabled();
		await expect(canvas.getByText('Label is required')).toBeVisible();
		// Type the label — the lane filter error takes its place.
		await userEvent.type(canvas.getByRole('textbox', { name: 'Lane 1 label' }), 'Low odds');
		await sleep(10);
		await expect(canvas.getByText('Choose a field, operator, and value')).toBeVisible();
		await expect(createBtn).toBeDisabled();
		// Add a second lane and give it the same label — the duplicate error
		// surfaces on the later lane.
		await fireEvent.click(canvas.getByRole('button', { name: 'Add lane' }));
		await sleep(20);
		await userEvent.type(canvas.getByRole('textbox', { name: 'Lane 2 label' }), 'Low odds');
		await sleep(10);
		await expect(canvas.getByText('Another lane uses this label')).toBeVisible();
		await expect(createBtn).toBeDisabled();
		// Complete both lanes: field Probability, operator ≤ / ≥, values 50/50.
		const body = within(document.body);
		await userEvent.click(canvas.getByRole('combobox', { name: 'Lane 1 field' }));
		await sleep(20);
		await userEvent.click(body.getAllByRole('option', { name: /Probability/ })[0]);
		await sleep(20);
		// The operator defaults to the first derived one (is) — switch to ≤.
		await userEvent.click(canvas.getByRole('combobox', { name: 'Lane 1 operator' }));
		await sleep(20);
		await userEvent.click(body.getAllByRole('option', { name: '≤' })[0]);
		await sleep(20);
		await userEvent.type(canvas.getByRole('spinbutton', { name: 'Lane 1 value' }), '50');
		await sleep(10);
		await userEvent.click(canvas.getByRole('combobox', { name: 'Lane 2 field' }));
		await sleep(20);
		await userEvent.click(body.getAllByRole('option', { name: /Probability/ })[0]);
		await sleep(20);
		await userEvent.click(canvas.getByRole('combobox', { name: 'Lane 2 operator' }));
		await sleep(20);
		await userEvent.click(body.getAllByRole('option', { name: '≥' })[0]);
		await sleep(20);
		await userEvent.type(canvas.getByRole('spinbutton', { name: 'Lane 2 value' }), '50');
		await sleep(10);
		// Rename the second lane so the labels are unique.
		const labels = canvas.getByRole('textbox', { name: 'Lane 2 label' }) as HTMLInputElement;
		await userEvent.clear(labels);
		await userEvent.type(labels, 'High odds');
		await sleep(10);
		// Pick the card sort: Probability descending — the `-` prefix composes.
		await userEvent.click(canvas.getByRole('combobox', { name: 'Card sort' }));
		await sleep(20);
		await userEvent.click(body.getAllByRole('option', { name: /Probability/ })[0]);
		await sleep(20);
		// The name is required too — fill it, then the save button enables.
		await userEvent.type(canvas.getByRole('textbox', { name: /Name/ }), 'By odds');
		await sleep(10);
		await expect(createBtn).toBeEnabled();
		await fireEvent.click(createBtn);
		await sleep(40);

		const after = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });
		const created = after.data
			.map((d) => d.data)
			.find((v) => (v as { name?: string }).name === 'By odds') as
			| {
					surface?: string;
					config?: {
						kanban?: {
							lanes?: { label: string; filter: Record<string, unknown> }[];
							sort?: string[];
						};
					};
			  }
			| undefined;
		expect(created).toBeTruthy();
		expect(created?.surface).toBe('kanban');
		expect(created?.config?.kanban?.lanes).toEqual([
			{ label: 'Low odds', filter: { probability__lte: '50' } },
			{ label: 'High odds', filter: { probability__gte: '50' } }
		]);
		expect(created?.config?.kanban?.sort).toEqual(['-probability']);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 900px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CreateKanbanCustomReference"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		await fireEvent.click(canvas.getByRole('button', { name: /Kanban/ }));
		await sleep(20);
		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);
		await fireEvent.click(canvas.getByRole('radio', { name: /Custom lanes/ }));
		await sleep(20);
		const createBtn = canvas.getByRole('button', { name: 'Create view' });
		await fireEvent.click(canvas.getByRole('button', { name: 'Add lane' }));
		await sleep(20);
		await userEvent.type(canvas.getByRole('textbox', { name: 'Lane 1 label' }), 'Acme deals');
		await sleep(10);
		// Field Company — a reference field. The operator derives to "is" and
		// the value control is the ReferencePicker, not a text input.
		const body = within(document.body);
		await userEvent.click(canvas.getByRole('combobox', { name: 'Lane 1 field' }));
		await sleep(20);
		await userEvent.click(body.getAllByRole('option', { name: /Company/ })[0]);
		await sleep(20);
		await expect(canvas.getByRole('combobox', { name: 'Lane 1 operator' })).toHaveValue('is');
		// Focus opens the record menu and lists the doctype's documents (empty
		// query → no debounce). Pick Acme Corp — the first seeded company.
		await fireEvent.focus(canvas.getByRole('searchbox', { name: 'Lane 1 value' }));
		await waitFor(() => {
			expect(canvas.queryByRole('option', { name: 'Acme Corp' })).toBeTruthy();
		});
		await userEvent.click(canvas.getByRole('option', { name: 'Acme Corp' }));
		await sleep(10);
		// The picker collapses to the hydrated capsule; the save gate lifts.
		await waitFor(() => {
			// Two spans render 'Acme Corp': the collapsed capsule and the
			// still-mounted record menu — assert the capsule class specifically.
			const capsules = canvas.getAllByText('Acme Corp');
			expect(capsules.some((el) => el.className.includes('ref-capsule-label'))).toBe(true);
		});
		await userEvent.type(canvas.getByRole('textbox', { name: /Name/ }), 'By company');
		await sleep(10);
		await expect(createBtn).toBeEnabled();
		await fireEvent.click(createBtn);
		await sleep(40);

		const after = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });
		const created = after.data
			.map((d) => d.data)
			.find((v) => (v as { name?: string }).name === 'By company') as
			| {
					surface?: string;
					config?: {
						kanban?: {
							lanes?: { label: string; filter: Record<string, unknown> }[];
						};
					};
			  }
			| undefined;
		expect(created).toBeTruthy();
		expect(created?.surface).toBe('kanban');
		// The lane value is the picker's emitted reference id — the row's bare
		// projection id. The mock's Company rows carry dotted ids
		// (`crm.Company.1`), so the stored filter names the row exactly; the
		// backend reference filter resolves both this id form and a fully
		// qualified token.
		expect(created?.config?.kanban?.lanes).toEqual([
			{ label: 'Acme deals', filter: { company_id__eq: 'crm.Company.1' } }
		]);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 900px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="EditKanbanLoadsConfig"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		// Edit mode skips the picker and shows the kanban form prefilled.
		await expect(canvas.getByRole('heading', { name: 'Edit view' })).toBeVisible();
		expect((canvas.getByRole('textbox', { name: /Name/ }) as HTMLInputElement).value).toBe(
			'By odds'
		);
		// Custom mode is active and both lane labels are loaded.
		await expect(canvas.getByRole('radio', { name: /Custom lanes/ })).toHaveAttribute(
			'aria-checked',
			'true'
		);
		const labels = [
			canvas.getByRole('textbox', { name: 'Lane 1 label' }),
			canvas.getByRole('textbox', { name: 'Lane 2 label' })
		] as HTMLInputElement[];
		expect(labels.map((l) => l.value)).toEqual(['Low odds', 'High odds']);
		// The stored lane filters parse back into the controls: field, then
		// operator trigger, then value. The Select trigger is an input — the
		// display text rides its value, not its text content.
		expect(canvas.getByRole('combobox', { name: 'Lane 1 field' })).toHaveValue('Probability');
		expect(canvas.getByRole('combobox', { name: 'Lane 1 operator' })).toHaveValue('≤');
		expect(canvas.getByRole('spinbutton', { name: 'Lane 1 value' })).toHaveValue(50);
		// The sort picker shows the parsed field and the descending direction.
		const sortSelect = canvas.getByRole('combobox', { name: 'Card sort' });
		expect(sortSelect).toHaveValue('Probability');
		await expect(canvas.getByRole('radio', { name: 'Descending' })).toHaveAttribute(
			'aria-checked',
			'true'
		);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 700px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewId="crm.Deal.collection_view.by_odds"
					view={{
						name: 'By odds',
						surface: 'kanban',
						config: {
							kanban: {
								mode: 'custom',
								page_size: 25,
								lanes: [
									{ label: 'Low odds', filter: { probability__lte: 50 } },
									{ label: 'High odds', filter: { probability__gte: 50 } }
								],
								sort: ['-probability']
							}
						}
					}}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CreateScopedHidesGeneral"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);
		// A `$mine`-scoped creator cannot make general views: the General radio
		// is gated behind <Can scope="unrestricted"> and must NOT render.
		await expect(canvas.getByText('Personal')).toBeVisible();
		await expect(canvas.queryByText('General')).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={scopedManifest} scopes={scopedScopes}>
			<div style="position: relative; width: 100%; min-height: 600px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CreatePersonalAndSave"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);

		const before = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });

		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);

		// Fill the name; default scope is Personal for a scoped creator.
		await userEvent.type(canvas.getByRole('textbox', { name: /Name/ }), 'My pipeline');
		await sleep(10);

		await fireEvent.click(canvas.getByRole('button', { name: 'Create view' }));
		await sleep(40);

		const after = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });
		expect(after.data.length).toBe(before.data.length + 1);
		const created = after.data
			.map((d) => d.data)
			.find((v) => (v as { name?: string }).name === 'My pipeline') as
			| { owner_id?: string }
			| undefined;
		expect(created).toBeTruthy();
		// Personal view: the client sets owner_id to the viewer (an unrestricted
		// creator must opt in explicitly since the Lua hook only force-binds it
		// for `$mine`-scoped creators).
		expect(created?.owner_id).toBe('iam.Account.viewer');
	}}
>
	{#snippet template()}
		<CanFixture manifest={scopedManifest} scopes={scopedScopes}>
			<div style="position: relative; width: 100%; min-height: 700px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CreateWithSystemColumns"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);

		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);

		// The picker offers the system-managed timestamp columns alongside the
		// doctype fields, labelled "Created At" / "Updated At".
		await expect(canvas.getByText('Created At')).toBeVisible();
		await expect(canvas.getByText('Updated At')).toBeVisible();
		await fireEvent.click(canvas.getByRole('button', { name: 'Add column created_at' }));
		await sleep(10);
		await fireEvent.click(canvas.getByRole('button', { name: 'Add column updated_at' }));
		await sleep(10);
		// Added entries leave the Available list and land in Selected with
		// their humanized labels as the default column headers. NOTE: scoped
		// to the live dialog — earlier stories' portals linger in
		// `document.body`, so an unscoped query matches their leftovers too.
		const dlgRoot = _canvasElement.closest<HTMLElement>('.cve-panel') ?? _canvasElement;
		const dlg = within(dlgRoot);
		await expect(dlg.queryByRole('button', { name: 'Add column created_at' })).toBeNull();
		await expect(dlg.queryByRole('button', { name: 'Add column updated_at' })).toBeNull();
		const createdAtHeader = canvas.getByRole('textbox', {
			name: 'Label for column created_at'
		}) as HTMLInputElement;
		expect(createdAtHeader.value).toBe('Created At');
		const updatedAtHeader = canvas.getByRole('textbox', {
			name: 'Label for column updated_at'
		}) as HTMLInputElement;
		expect(updatedAtHeader.value).toBe('Updated At');

		await userEvent.type(canvas.getByRole('textbox', { name: /Name/ }), 'With timestamps');
		await sleep(10);
		await fireEvent.click(canvas.getByRole('button', { name: 'Create view' }));
		await sleep(40);

		// The persisted config carries both system columns with their labels.
		const after = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });
		const created = after.data
			.map((d) => d.data)
			.find((v) => (v as { name?: string }).name === 'With timestamps') as
			| { config?: { columns?: { key?: string; label?: string }[] } }
			| undefined;
		expect(created).toBeTruthy();
		const columnFor = (key: string) => (created?.config?.columns ?? []).find((c) => c.key === key);
		expect(columnFor('created_at')).toEqual({ key: 'created_at', label: 'Created At' });
		expect(columnFor('updated_at')).toEqual({ key: 'updated_at', label: 'Updated At' });
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 700px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="ReorderColumns"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		await fireEvent.click(canvas.getByRole('button', { name: 'Next' }));
		await sleep(20);

		// Default columns seed from the doctype's first 4 flat fields. Read the
		// seeded order instead of hardcoding it — the fixture pipeline may
		// reorder keys. The seed rule itself is pinned in config.spec.ts.
		const rows = () =>
			canvas
				.getAllByRole('textbox')
				.filter((el) => (el.getAttribute('aria-label') ?? '').startsWith('Label for column'));
		await expect(rows()).toHaveLength(4);
		const labelAt = (i: number) => rows()[i].getAttribute('aria-label') ?? '';
		const before = [labelAt(0), labelAt(1), labelAt(2), labelAt(3)];
		await expect(before[0]).toBeTruthy();

		// The first row cannot move up; moving the second row up swaps the two.
		const up = canvas.getAllByRole('button', { name: 'Move up' });
		await expect(up[0]).toBeDisabled();
		await fireEvent.click(up[1]);
		await sleep(10);
		await expect(labelAt(0)).toBe(before[1]);
		await expect(labelAt(1)).toBe(before[0]);
		// Trailing rows keep their order.
		await expect(labelAt(2)).toBe(before[2]);
		await expect(labelAt(3)).toBe(before[3]);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 600px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="EditExisting"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		// Edit mode skips the picker and shows the config form directly.
		await expect(canvas.getByRole('heading', { name: 'Edit view' })).toBeVisible();
		// owner_id is immutable → scope is a read-only badge, not radios.
		await expect(canvas.getByText('General')).toBeVisible();
		await expect(canvas.queryByRole('radiogroup')).toBeNull();
		// The existing view's name ("All Deals") is prefilled.
		expect((canvas.getByRole('textbox', { name: /Name/ }) as HTMLInputElement).value).toBe(
			'All Deals'
		);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 600px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewId="crm.Deal.collection_view.all"
					view={{
						name: 'All Deals',
						surface: 'table',
						config: {
							columns: [
								{ key: 'title', label: 'Deal' },
								{ key: 'value', label: 'Value', width: '120px' }
							]
						}
					}}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="EditCalendarSave"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		// Edit mode skips the picker and shows the calendar config form.
		await expect(canvas.getByRole('heading', { name: 'Edit view' })).toBeVisible();
		const nameInput = canvas.getByRole('textbox', { name: /Name/ }) as HTMLInputElement;
		expect(nameInput.value).toBe('Timeline');
		// The discriminator is prefilled from the existing view.
		await expect(canvas.getByLabelText('Date field')).toHaveValue('Expected Close Date');

		// Rename and save — the PATCH body is a plain partial document.
		await userEvent.clear(nameInput);
		await userEvent.type(nameInput, 'Timeline v2');
		await sleep(10);
		await fireEvent.click(canvas.getByRole('button', { name: 'Save changes' }));
		await sleep(40);

		const after = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });
		const updated = after.data
			.map((d) => d.data)
			.find((v) => (v as { name?: string }).name === 'Timeline v2') as
			| { surface?: string; config?: { calendar?: { discriminator?: string } } }
			| undefined;
		expect(updated).toBeTruthy();
		expect(updated?.surface).toBe('calendar');
		expect(updated?.config?.calendar?.discriminator).toBe('expected_close_date');
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 600px;">
				<CollectionViewEditor
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					viewId="crm.Deal.collection_view.timeline"
					view={{
						name: 'Timeline',
						surface: 'calendar',
						config: {
							calendar: {
								discriminator: 'expected_close_date',
								color_by: 'status',
								title_template: '{title}',
								week_start: 'monday'
							}
						}
					}}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CancelCloses"
	play={async ({ canvasElement: _canvasElement }) => {
		await sleep(50);
		const canvas = within(document.body);
		await expect(canvas.getByRole('heading', { name: 'New view' })).toBeVisible();
		await fireEvent.click(canvas.getByRole('button', { name: 'Close' }));
		await sleep(30);
		// onclose unmounts the editor (the wrapper drops it when `open` is false).
		expect(canvas.queryByRole('heading', { name: 'New view' })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="position: relative; width: 100%; min-height: 600px;">
				{#if open}
					<CollectionViewEditor
						{driver}
						doctype={dealDef}
						parentDocId="crm.Deal"
						viewerId="iam.Account.viewer"
						onclose={() => (open = false)}
					/>
				{/if}
			</div>
		</CanFixture>
	{/snippet}
</Story>

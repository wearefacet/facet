<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
	import DocumentForm from './DocumentForm.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { parseDoctypeDef } from '$lib/doctype/types.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { TemplateNode } from '$lib/template-types';
	import { setVisibleTags } from '$lib/permissions.svelte';

	const driver = createMockDriver();

	// Dedicated driver for the composition-child story — its play mutes the
	// shared fixture store with a new Task document, so it must not share
	// state with the other stories.
	const childDriver = createMockDriver();
	const taskRaw = childDriver.getDoctypeDefinition('production.Task');
	const taskChildDef: DoctypeDef = parseDoctypeDef(taskRaw as Record<string, unknown>);

	// Dedicated driver for the structured-field gate story — its play counts
	// Widget creates, so it must not share state with the other stories.
	const structuredDriver = createMockDriver();

	/**
	 * Definition with one structured field — the B-118 gate surface. The
	 * fallback form renders `address` through `StructuredInput`, whose parse
	 * validity gates the save.
	 */
	const structuredDef: DoctypeDef = {
		doctype: 'Widget',
		domain: 'crm',
		fields: [
			{ key: 'label', type: 'string' },
			{
				key: 'address',
				type: 'object',
				title: 'Address',
				properties: [{ key: 'street', type: 'string' }]
			}
		],
		children: [],
		actions: []
	};

	/**
	 * B-294 surface: a fallback form with a `url` field. Its blur gate
	 * (`urlFieldError`) refuses scheme-less values the same way the
	 * backend's `UrlType` refuses them on the REST path.
	 */
	const urlFieldDef: DoctypeDef = {
		doctype: 'Widget',
		domain: 'crm',
		fields: [{ key: 'website', type: 'url', title: 'Website' }],
		children: [],
		actions: []
	};

	/**
	 * Definition mirroring the server-stamped field shapes of the system
	 * doctypes (`core.Webhook.secret`/`account_id`, `app.App.client_id`): a
	 * read-only field the backend rejects in input with a 422, and a
	 * `secret` field whose persisted value is a `{mode, version, set_at}`
	 * marker that must never bind into a plain text input. The fallback form
	 * skips the read-only field and renders the secret one through the
	 * stage/adopt affordance (`DvtInputSecret`).
	 */
	const stampedDef: DoctypeDef = {
		doctype: 'Widget',
		domain: 'crm',
		fields: [
			{ key: 'label', type: 'string', required: true },
			{ key: 'enabled', type: 'boolean' },
			{ key: 'revision', type: 'integer', read_only: true },
			{ key: 'client_id', type: 'string', read_only: true },
			{ key: 'client_secret', type: 'secret', mode: 'sealed' }
		],
		children: [],
		actions: []
	};

	/**
	 * Definition with one `secret` field (B-129) — the fallback form renders it
	 * through `DvtInputSecret`, the same stage/adopt affordance the template
	 * form's `input-secret` node uses.
	 */
	const secretDef: DoctypeDef = {
		doctype: 'Widget',
		domain: 'crm',
		fields: [
			{ key: 'label', type: 'string' },
			{ key: 'api_key', type: 'secret', mode: 'sealed', title: 'API Key' }
		],
		children: [],
		actions: []
	};

	/**
	 * B-176 surface: a `secret` field tagged `pay` — invisible to a role whose
	 * `visible_tags` do not cover the tag. The read mask already omitted the
	 * field's value; the fallback form must not offer the "Set value"
	 * affordance either (the write guard would refuse it with 403).
	 */
	const taggedSecretDef: DoctypeDef = {
		doctype: 'Employee',
		domain: 'hr',
		fields: [
			{ key: 'label', type: 'string', title: 'Label' },
			{ key: 'salary', type: 'secret', mode: 'sealed', tags: ['pay'], title: 'Salary' }
		],
		children: [],
		actions: []
	};

	// Dedicated driver for the secret-stage story — its play creates a Widget,
	// so it must not share state with the other stories.
	const secretDriver = createMockDriver();

	/**
	 * F01-5 surface: a doctype whose one field is a single-value reference.
	 * The fallback form must render the ReferencePicker, not a plain input.
	 */
	const referenceFieldDef: DoctypeDef = {
		doctype: 'Deal',
		domain: 'crm',
		fields: [{ key: 'company', type: 'reference', doctype: 'Company', title: 'Company' }],
		children: [],
		actions: []
	};

	/**
	 * Date-family surface: the four date and range field types. The fallback
	 * form renders each through its picker (`DatetimePicker` for `date` and
	 * `datetime`, `PeriodPicker` for `period` and `dateperiod`) — never the
	 * plain-text input.
	 */
	const dateFamilyDef: DoctypeDef = {
		doctype: 'Widget',
		domain: 'crm',
		fields: [
			{ key: 'label', type: 'string', title: 'Label' },
			{ key: 'starts_at', type: 'datetime', title: 'Starts At' },
			{ key: 'hire_date', type: 'date', title: 'Hire Date' },
			{ key: 'window', type: 'period', title: 'Window' },
			{ key: 'busy_dates', type: 'dateperiod', title: 'Busy Dates' }
		],
		children: [],
		actions: []
	};

	/**
	 * B-314 surface: a fallback form (no `kind: form` template) on a doctype
	 * that declares children. The dedicated driver owns its own fixture store
	 * (the standard seed carries `hr.CandidateExperience` with a `form` view),
	 * so the play's create does not leak into the other stories.
	 */
	const childrenFormDriver = createMockDriver();

	const childrenFormDef: DoctypeDef = {
		doctype: 'Candidate',
		domain: 'hr',
		fields: [{ key: 'name', type: 'string' }],
		children: [{ key: 'experiences', doctype: 'CandidateExperience' }],
		actions: []
	};

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DocumentForm',
		component: DocumentForm,
		tags: ['autodocs'],
		argTypes: {
			def: { control: 'object' },
			view: { control: 'object' }
		}
	});

	/** Wait long enough for the first render to settle in Storybook. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

	/**
	 * B-191 surface: a template form whose root node edits the secret field.
	 * The stage registrar reaches the widget through `DocumentViewTemplate`.
	 */
	const secretTemplateNode: TemplateNode = {
		type: 'input-secret',
		field: 'api_key',
		label: 'API Key'
	};
</script>

<!-- The fallback form (no `kind: form` template): one input per editable
	scalar field. Read-only fields render no input — they cannot round-trip
	through the generic bag (read-only → 422). Regression for the
	formSeed/formDiff read_only fix. Secret fields render the stage/adopt
	affordance instead (see `FallbackSecretStage`). -->
<Story
	name="FallbackSkipsStampedFields"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// Editable scalars render (the fallback humanizes untitled keys —
		// "label" renders as "Label"; the toggle's label is not
		// an accessible name, so assert the text and the switch role).
		await expect(canvas.getByText('Label')).toBeVisible();
		await expect(canvas.getByText('Enabled')).toBeVisible();
		expect(canvas.getAllByRole('switch').length).toBe(1);
		// Read-only fields render no input and no label.
		expect(canvas.queryByText('Revision')).toBeNull();
		expect(canvas.queryByText('Client Id')).toBeNull();
		// The secret field renders the stage affordance, not a text input.
		await expect(canvas.getByText('Client Secret')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Set value' })).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={stampedDef}
				view={{ kind: 'form', template: null }}
				{driver}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-294: the fallback form's url inputs run the same commit as the
	template form's `input-text` node — a dotted bare host is completed with
	the implied scheme, a dotless value is refused with a field error at
	blur instead of silently reaching the wire. -->
<Story
	name="FallbackUrlBlurGate"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		const input = canvas.getByRole('textbox');
		// A dotless scheme-less value is refused, not completed into a url.
		await userEvent.type(input, 'not-a-url');
		await expect(canvas.getByText('https://')).toBeVisible();
		await userEvent.tab();
		await expect(
			canvas.getByText(
				'Not a valid URL (expected an absolute http(s):// address with a valid host).'
			)
		).toBeVisible();
		// A dotted bare host is completed on commit — the field shows the
		// form the backend stores, and the error clears.
		await userEvent.clear(input);
		await userEvent.type(input, 'www.acme.tld');
		await userEvent.tab();
		await waitFor(() => {
			expect(canvas.getByDisplayValue('https://www.acme.tld')).toBeVisible();
		});
		await expect(canvas.queryByText(/Not a valid URL/)).toBeNull();
		await expect(canvas.queryByText('https://')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={urlFieldDef}
				view={{ kind: 'form', template: null }}
				{driver}
			/>
		</div>
	{/snippet}
</Story>

<!-- The fallback form renders the date-family fields through their pickers —
	DatetimePicker for `date` and `datetime`, PeriodPicker for `period` and
	`dateperiod` — never the plain-text input. The pickers carry known axe
	violations (see their own stories), so the scan is waived here too. -->
<Story
	name="FallbackRendersDateFamily"
	parameters={{ a11y: { test: 'todo' } }}
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// One picker per field: the datetime picker, the date picker, and two
		// bounds each for the period and the dateperiod — six year segments.
		expect(canvas.getAllByLabelText('year').length).toBe(6);
		// The datetime picker and the two period bounds own hour segments.
		expect(canvas.getAllByLabelText('hour').length).toBe(3);
		// None of the four fields renders the plain-text input.
		expect(canvas.queryByRole('textbox', { name: 'Starts At' })).toBeNull();
		expect(canvas.queryByRole('textbox', { name: 'Hire Date' })).toBeNull();
		expect(canvas.queryByRole('textbox', { name: 'Window' })).toBeNull();
		expect(canvas.queryByRole('textbox', { name: 'Busy Dates' })).toBeNull();
		// The string field keeps the plain-text input.
		await expect(canvas.getByRole('textbox', { name: 'Label' })).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={dateFamilyDef}
				view={{ kind: 'form', template: null }}
				{driver}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-314: the fallback form renders an editable relation section per
	`def.children` entry — the same drafts machinery the template path uses.
	The staged draft persists through the parent's nested children route on
	save. The DvtRelation surface carries known axe violations (see its own
	stories), so the scan is waived here too. -->
<Story
	name="FallbackRendersChildren"
	parameters={{ a11y: { test: 'todo' } }}
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// One relation section per def.children entry.
		await expect(canvas.getByText('Experiences')).toBeVisible();
		// Add stages a draft row for the relation; the row renders the child
		// doctype's form template once its view loads.
		await userEvent.click(
			canvas.getByRole('button', { name: m.doc_relation_add_aria({ label: 'Experiences' }) })
		);
		await waitFor(() => {
			expect(canvasElement.querySelector('[data-row-id]')).not.toBeNull();
		});
		// A fully blank draft is a no-op on save — type into the row so the
		// draft is a real create.
		const title = await waitFor(() => canvas.getByRole('textbox', { name: 'Title' }));
		await userEvent.type(title, 'Staff Engineer');
		// Saving the parent persists the staged child on the nested route —
		// the created child id carries the `.experiences.` rel segment. The
		// mock scopes children by id prefix, so assert on the parent's
		// children list (the ChildCreateParentPicker pattern).
		await userEvent.click(canvas.getByRole('button', { name: m.common_create() }));
		await waitFor(async () => {
			const parents = await childrenFormDriver.domain('hr').doctype('Candidate').list({
				items: 100
			});
			const kidIds = await Promise.all(
				parents.data.map(async (p) => {
					const kids = await childrenFormDriver
						.domain('hr')
						.doctype('Candidate')
						.doc(p.meta.id)
						.children('experiences')
						.list({ items: 100 });
					return kids.data.map((c) => c.meta.id);
				})
			);
			expect(kidIds.flat().some((id) => id.includes('.experiences.'))).toBe(true);
		});
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={childrenFormDef}
				view={{ kind: 'form', template: null }}
				driver={childrenFormDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- Composition child create (a `member_of` doctype, e.g. the seeded
	`production.Task` under `production.Project`): the form renders a required
	parent picker locked to the parent doctype and gates the save on it. The
	save routes through the parent's nested route
	(`doc(parentId).children(rel)`) — the flat create would 422 (the backend
	stamps the system-managed `meta.parent_id` only on the nested route). -->
<Story
	name="ChildCreateParentPicker"
	parameters={{
		// The ReferencePicker surface carries known axe violations (audit 22,
		// see its own stories) — inherited by any story that embeds it.
		a11y: { test: 'todo' }
	}}
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// The picker renders, locked to the parent doctype.
		await expect(canvas.getByText('Parent Project')).toBeVisible();
		const locked = canvasElement.querySelector('.ref-type-locked');
		await expect(locked).not.toBeNull();
		await expect(locked?.getAttribute('aria-label')).toBe('Project');

		// Saving without a parent is gated client-side — the required message
		// shows and no task is created.
		const before = await childDriver.domain('production').doctype('Task').list({ items: 500 });
		await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
		await expect(canvas.getByText('Select a parent Project.')).toBeVisible();
		const afterGate = await childDriver.domain('production').doctype('Task').list({ items: 500 });
		expect(afterGate.data.length).toBe(before.data.length);

		// Pick a parent from the dropdown (focus opens it; the empty query
		// lists the seeded projects) and save — the create lands on the
		// nested route, so the new task id carries the `.tasks.` rel segment.
		// Scoped to the parent picker: the fallback form also renders the
		// task's `assignee` reference field through its own picker.
		const input = within(canvasElement.querySelector('.parent-picker') as HTMLElement).getByRole(
			'searchbox'
		);
		await userEvent.click(input);
		await waitFor(() => {
			expect(canvas.getAllByRole('option').length).toBeGreaterThan(0);
		});
		await userEvent.click(canvas.getAllByRole('option')[0]);
		await waitFor(() => {
			expect(canvasElement.querySelector('.ref-capsule')).not.toBeNull();
		});
		await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
		// The mock files a nested create under the parent's doc_type bucket, so
		// assert on the parent's children list — the mock scopes it by id
		// prefix, and the `.tasks.` segment only occurs on a create issued
		// through the nested route (fixture seeds use `.task.`).
		await waitFor(async () => {
			const projects = await childDriver
				.domain('production')
				.doctype('Project')
				.list({ items: 500 });
			const kidIds = await Promise.all(
				projects.data.map(async (p) => {
					const kids = await childDriver
						.domain('production')
						.doctype('Project')
						.doc(p.meta.id)
						.children('tasks')
						.list({ items: 500 });
					return kids.data.map((c) => c.meta.id);
				})
			);
			expect(kidIds.flat().some((id) => id.includes('.tasks.'))).toBe(true);
		});
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={taskChildDef}
				view={{ kind: 'form', template: null }}
				driver={childDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-118: structured text that does not parse must not save. Invalid
	JSON and a schema mismatch each block the Create call — the values bag
	still holds the last valid structure, so a save would silently drop the
	field or send stale content — and the field error stays visible. A valid
	text saves and stores the parsed structure. -->
<Story
	name="StructuredInvalidBlocksSave"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// The fallback form renders exactly one textarea — the address field.
		const box = canvasElement.querySelector('textarea') as HTMLTextAreaElement;
		expect(box).not.toBeNull();
		const before = await structuredDriver.domain('crm').doctype('Widget').list({ items: 500 });

		// Invalid JSON: the field error shows and Create saves nothing.
		await userEvent.type(box, '{{"street": ');
		await waitFor(() => expect(canvas.getByRole('alert')).toHaveTextContent(/Invalid JSON/));
		await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
		await expect(
			canvas.getByText('Some fields hold invalid JSON. Fix them before you save.')
		).toBeVisible();
		const afterInvalid = await structuredDriver
			.domain('crm')
			.doctype('Widget')
			.list({ items: 500 });
		expect(afterInvalid.data.length).toBe(before.data.length);

		// A schema mismatch blocks too — the alert names the offending path.
		// The banner stays until the next save attempt, so the alert role is
		// ambiguous here; assert the field message by its text.
		await userEvent.clear(box);
		await userEvent.type(box, '{{"street":42}');
		await waitFor(() => expect(canvas.getByText(/address\.street must be a string/)).toBeVisible());
		await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
		const afterMismatch = await structuredDriver
			.domain('crm')
			.doctype('Widget')
			.list({ items: 500 });
		expect(afterMismatch.data.length).toBe(before.data.length);

		// A valid text saves and stores the parsed structure; the banner
		// clears at the start of the save.
		await userEvent.clear(box);
		await userEvent.type(box, '{{"street":"Elm St"}');
		await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
		await waitFor(async () => {
			const after = await structuredDriver.domain('crm').doctype('Widget').list({ items: 500 });
			expect(after.data.length).toBe(before.data.length + 1);
			expect(after.data.at(-1)?.data.address).toEqual({ street: 'Elm St' });
		});
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={structuredDef}
				view={{ kind: 'form', template: null }}
				driver={structuredDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-129: the fallback form renders a `secret` field through `DvtInputSecret`.
	Staging a plaintext posts to `/Api/secrets/stage` and writes the returned
	handle into the values bag, so the normal create flow adopts it. The fetch
	is mocked — the story asserts the request body and the adopted handle. -->
<Story
	name="FallbackSecretStage"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// The secret field renders its label and the "Set value" affordance.
		await expect(canvas.getByText('API Key')).toBeVisible();
		const setBtn = canvas.getByRole('button', { name: 'Set value' });

		// Mock the stage route: capture the request body and answer a handle.
		const original = window.fetch;
		let staged: Record<string, unknown> | null = null;
		window.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
			if (String(input).includes('/Api/secrets/stage')) {
				staged = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>;
				return new Response(JSON.stringify({ handle: 'sh_TESTHANDLE' }), {
					status: 201,
					headers: { 'Content-Type': 'application/json' }
				});
			}
			return original(input, init);
		}) as typeof fetch;
		try {
			await userEvent.click(setBtn);
			const input = canvas.getByLabelText('API Key') as HTMLInputElement;
			await userEvent.type(input, 'hunter2');
			await userEvent.tab();
			// The staged state renders the marker badge; the plaintext is gone.
			await waitFor(() => expect(canvas.getByText('set · sealed')).toBeVisible(), {
				timeout: 4000
			});
			expect(canvas.queryByText('hunter2')).toBeNull();
			// The plaintext reached the stage route bound to the right field.
			expect(staged).toMatchObject({
				domain: 'crm',
				doctype: 'Widget',
				field_path: 'api_key',
				value: 'hunter2'
			});

			// The handle landed in the values bag: the create flow adopts it and
			// the stored content carries the handle, never the plaintext.
			await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
			await waitFor(async () => {
				const after = await secretDriver.domain('crm').doctype('Widget').list({ items: 500 });
				expect(after.data.at(-1)?.data.api_key).toBe('sh_TESTHANDLE');
			});
		} finally {
			window.fetch = original;
		}
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={secretDef}
				view={{ kind: 'form', template: null }}
				driver={secretDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-191: a save that races an in-flight stage waits for the handle. The
	stage round-trip is held behind a gate; the save stays pending until the
	gate releases, then adopts the handle into the created document. The
	template path exercises the registrar threading through
	`DocumentViewTemplate`. -->
<Story
	name="SecretStageInFlightWaitsForSave"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// Hold the stage response until the play releases it.
		const original = window.fetch;
		let releaseStage!: () => void;
		const gate = new Promise<void>((resolve) => {
			releaseStage = resolve;
		});
		window.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
			if (String(input).includes('/Api/secrets/stage')) {
				await gate;
				return new Response(JSON.stringify({ handle: 'sh_LATEHANDLE' }), {
					status: 201,
					headers: { 'Content-Type': 'application/json' }
				});
			}
			return original(input, init);
		}) as typeof fetch;
		try {
			const before = await secretDriver.domain('crm').doctype('Widget').list({ items: 500 });
			await userEvent.click(canvas.getByRole('button', { name: 'Set value' }));
			const input = canvas.getByLabelText('API Key') as HTMLInputElement;
			await userEvent.type(input, 'hunter2');
			await userEvent.tab();
			// The stage is in flight and held by the gate.
			await expect(canvas.getByText('Staging…')).toBeVisible();

			// Save while the stage is in flight — the form waits for the handle.
			await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
			await sleep(100);
			const gated = await secretDriver.domain('crm').doctype('Widget').list({ items: 500 });
			expect(gated.data.length).toBe(before.data.length);

			// Release the stage: the save resumes and adopts the handle.
			releaseStage();
			await waitFor(async () => {
				const after = await secretDriver.domain('crm').doctype('Widget').list({ items: 500 });
				expect(after.data.length).toBe(before.data.length + 1);
				expect(after.data.at(-1)?.data.api_key).toBe('sh_LATEHANDLE');
			});
		} finally {
			window.fetch = original;
		}
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={secretDef}
				view={{ kind: 'form', template: secretTemplateNode }}
				driver={secretDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-191: a failed stage fails the save loudly. The banner names the
	block, the inline field error keeps the reason, and no document is
	written — a retry stays blocked until the field's next stage attempt
	supersedes the failure. -->
<Story
	name="SecretStageFailureBlocksSave"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		const original = window.fetch;
		window.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
			if (String(input).includes('/Api/secrets/stage')) {
				return new Response(JSON.stringify({ error: 'Stage exploded' }), {
					status: 500,
					headers: { 'Content-Type': 'application/json' }
				});
			}
			return original(input, init);
		}) as typeof fetch;
		try {
			const before = await secretDriver.domain('crm').doctype('Widget').list({ items: 500 });
			await userEvent.click(canvas.getByRole('button', { name: 'Set value' }));
			const input = canvas.getByLabelText('API Key') as HTMLInputElement;
			await userEvent.type(input, 'hunter2');
			await userEvent.tab();
			// The stage failed — the inline reason renders on the field.
			await waitFor(() => expect(canvas.getByRole('alert')).toHaveTextContent('Stage exploded'), {
				timeout: 4000
			});

			// The save stops loudly and writes nothing.
			await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
			await expect(canvas.getByText('Staging failed')).toBeVisible();
			const afterFailed = await secretDriver.domain('crm').doctype('Widget').list({ items: 500 });
			expect(afterFailed.data.length).toBe(before.data.length);

			// A retry stays blocked while the failed attempt is the field's
			// latest stage state.
			await userEvent.click(canvas.getByRole('button', { name: 'Create' }));
			await expect(canvas.getByText('Staging failed')).toBeVisible();
			const afterRetry = await secretDriver.domain('crm').doctype('Widget').list({ items: 500 });
			expect(afterRetry.data.length).toBe(before.data.length);
		} finally {
			window.fetch = original;
		}
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={secretDef}
				view={{ kind: 'form', template: null }}
				driver={secretDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-176: a tagged secret field invisible to the active role renders no
	input and no "Set value" affordance — the write guard would refuse it
	with 403. The visible untagged field renders next to it. The store is
	set (and reset) inside the play, so other stories keep the fail-open
	null-store default. -->
<Story
	name="FallbackSkipsInvisibleFields"
	play={async ({ canvasElement }) => {
		setVisibleTags(['default']);
		try {
			await sleep(50);
			const canvas = within(canvasElement);
			await expect(canvas.getByText('Label')).toBeVisible();
			// The invisible field renders nothing at all.
			expect(canvas.queryByText('Salary')).toBeNull();
			expect(canvas.queryByRole('button', { name: 'Set value' })).toBeNull();
		} finally {
			setVisibleTags(null);
		}
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={taggedSecretDef}
				view={{ kind: 'form', template: null }}
				driver={secretDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- F01-5: a single-value reference field in the fallback form renders the
	ReferencePicker (locked target slot) instead of a plain text input. The
	picker's locked slot labels itself from the qualified target, so the
	assertion keys on the picker's own chrome. -->
<Story
	name="FallbackReferencePicker"
	parameters={{
		// The ReferencePicker surface carries known axe violations (audit 22,
		// see its own stories) — inherited by any story that embeds it.
		a11y: { test: 'todo' }
	}}
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		// The picker renders: the locked doctype slot carries the target name.
		await expect(canvas.getByText('Company', { selector: '.ref-tlabel' })).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="max-width: 720px; padding: 24px;">
			<DocumentForm
				mode="create"
				def={referenceFieldDef}
				view={{ kind: 'form', template: null }}
				{driver}
			/>
		</div>
	{/snippet}
</Story>

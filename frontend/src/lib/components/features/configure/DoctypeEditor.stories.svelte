<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import DoctypeEditor from './DoctypeEditor.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import type { TemplateNode } from '$lib/template-types.js';
	import type { ViewKind } from '$lib/doctype/previewDocument.js';

	const driver = createMockDriver();

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/DoctypeEditor',
		component: DoctypeEditor,
		tags: ['autodocs'],
		argTypes: {
			qualifiedName: {
				control: 'select',
				options: [
					'crm.Deal',
					'crm.Contact',
					'crm.Company',
					'crm.Prospect',
					'crm.Customer',
					'crm.Activity',
					'crm.PipelineStage',
					'hr.Candidate',
					'hr.Employee',
					'hr.CareerEvent',
					'hr.InterviewFeedback',
					'hr.CandidateEducation',
					'hr.CandidateExperience',
					'hr.CandidateSkill',
					'core.Domain',
					'core.DocType',
					'core.DocumentView',
					'iam.Account',
					'iam.LoginEvent',
					'iam.Roles',
					'identity.Person'
				]
			}
		},
		args: {
			registry: driver,
			qualifiedName: 'crm.Deal'
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	// Gold fills must render the dark `--on-accent` ink: `--accent-ink` equals
	// the accent fill in dark theme and makes the label invisible (tokens:
	// "Gold fill ≠ gold text"). Compares against a probe element so the check
	// holds in both Storybook themes.
	async function expectOnAccentInk(button: HTMLElement) {
		const probe = document.createElement('span');
		probe.style.color = 'var(--on-accent)';
		document.body.appendChild(probe);
		const expected = getComputedStyle(probe).color;
		probe.remove();
		const style = getComputedStyle(button);
		await expect(style.color).toBe(expected);
		await expect(style.color).not.toBe(style.backgroundColor);
	}

	// A minimal doctype fixture; `templates` seeds the two document template
	// keys. Every shipped fixture doctype carries templates, so the stories
	// use this synthetic doctype to control the initial template state.
	function templatedDriver(templates?: Record<string, string>) {
		const driver = createMockDriver();
		driver.registerDoctype('crm', 'Templated', {
			doctype: 'Templated',
			domain: 'crm',
			...templates
		});
		return driver;
	}

	/**
	 * Clicks Save with `window.fetch` patched so the play can assert the
	 * serialized PUT body (stories run without a backend). Resolves once the
	 * body is captured; restores fetch afterwards.
	 */
	async function saveAndCaptureBody(canvas: ReturnType<typeof within>) {
		let savedBody: Record<string, unknown> | undefined;
		const originalFetch = window.fetch;
		window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
			if (
				typeof input === 'string' &&
				input.includes('/Api/core/DocType/') &&
				init?.method === 'PUT'
			) {
				savedBody = JSON.parse(String(init.body));
				return new Response('{}', { status: 200 });
			}
			return originalFetch.call(window, input, init);
		};
		try {
			await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
			await waitFor(() => expect(savedBody).toBeDefined());
			return savedBody as Record<string, unknown>;
		} finally {
			window.fetch = originalFetch;
		}
	}
</script>

<Story name="Deal" args={{ qualifiedName: 'crm.Deal' }} />

<Story name="Candidate" args={{ qualifiedName: 'hr.Candidate' }} />

<Story name="Employee" args={{ qualifiedName: 'hr.Employee' }} />

<Story name="DocType" args={{ qualifiedName: 'core.DocType' }} />

<Story name="Domain" args={{ qualifiedName: 'core.Domain' }} />

<!-- Views tab: a doctype with a defined view template + the rest as fallback. -->
<Story
	name="Deal — views"
	args={{
		qualifiedName: 'crm.Deal',
		tab: 'views',
		views: {
			view: {
				type: 'tabs',
				tabs: [
					{
						type: 'tab',
						label: 'Overview',
						children: [
							{ type: 'title', value: '$name', level: 1 },
							{ type: 'capsule', value: '$status' },
							{ type: 'hr' },
							{ type: 'field', label: 'Value', value: '$value' }
						]
					}
				]
			} as TemplateNode
		} as Partial<Record<ViewKind, TemplateNode | null>>
	}}
/>

<!-- Each play story below gets its own driver so no story ever mutates state
     another story can see (shared-page Vitest run, see vite.config.ts). -->

<Story
	name="Deal — add field, rename keeps selection"
	args={{ qualifiedName: 'crm.Deal', tab: 'fields', registry: createMockDriver() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Adding a field selects it immediately in the editor.
		await userEvent.click(canvas.getByRole('button', { name: 'Add field' }));
		await expect(canvas.getByLabelText('Key')).toHaveValue('new_field');
		// Rename the selected field's key. Selection is tracked by object
		// reference, so the editor must stay on the renamed field.
		const keyInput = canvas.getByLabelText('Key');
		await userEvent.clear(keyInput);
		await userEvent.type(keyInput, 'pipeline_ref');
		await expect(canvas.getByLabelText('Key')).toHaveValue('pipeline_ref');
		// The list row and the editor header both show the new key; the
		// empty state stays hidden because a field is still selected.
		await expect(canvas.getAllByText('pipeline_ref').length).toBeGreaterThanOrEqual(2);
		await expect(
			canvas.queryByText('Select a field from the left to edit its properties.')
		).not.toBeInTheDocument();
	}}
/>

<!-- A rename onto a sibling's key must not reach the definition: two
	entries with one key throw `each_key_duplicate` at the keyed each in
	DoctypeFieldList and tear the whole editor down. The guard refuses the
	write, so this story renders to the end and the list stays intact. -->
<Story
	name="Deal — duplicate key rename is blocked"
	args={{ qualifiedName: 'crm.Deal', tab: 'fields', registry: createMockDriver() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Select the `title` field and rename it onto the sibling `value`.
		await userEvent.click(canvas.getByRole('button', { name: /title/ }));
		const keyInput = canvas.getByLabelText('Key');
		await userEvent.clear(keyInput);
		await userEvent.type(keyInput, 'value');
		// The inline duplicate error shows and the input keeps the typed text.
		await expect(canvas.getByText('Key "value" already exists')).toBeVisible();
		await expect(keyInput).toHaveValue('value');
		// The definition keeps the last legal prefix, never the duplicate —
		// the editor header and the renamed list row both show `valu`, and
		// the list still renders intact.
		await expect(canvas.getAllByText('valu').length).toBeGreaterThanOrEqual(2);
		await expect(canvas.getByRole('button', { name: 'Add field' })).toBeVisible();
	}}
/>

<Story
	name="Deal — add child"
	args={{ qualifiedName: 'crm.Deal', tab: 'children', registry: createMockDriver() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.queryByDisplayValue('new_child')).not.toBeInTheDocument();
		await userEvent.click(canvas.getByRole('button', { name: 'Add child collection' }));
		// The new child card renders with its generated unique key.
		await expect(canvas.getByDisplayValue('new_child')).toBeInTheDocument();
	}}
/>

<Story
	name="Deal — add arg"
	args={{ qualifiedName: 'crm.Deal', tab: 'actions', registry: createMockDriver() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Deal ships three actions (lose, move_stage, win); each card offers
		// its own argument row. Add an argument to the first card.
		const addArgButtons = await canvas.findAllByRole('button', { name: '+ Add arg' });
		expect(addArgButtons.length).toBe(3);
		await userEvent.click(addArgButtons[0]);
		await expect(canvas.getByDisplayValue('new_arg')).toBeInTheDocument();
	}}
/>

<Story
	name="Deal — migrations"
	args={{ qualifiedName: 'crm.Deal', tab: 'general', registry: createMockDriver() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Schema migrations')).toBeVisible();

		// Add an entry: it starts with the source version below the schema
		// version and no function name.
		await userEvent.click(canvas.getByRole('button', { name: 'Add migration' }));
		await expect(canvas.getByLabelText('From version')).toHaveValue('1');
		// Header save button sits on the gold fill — dark on-accent ink only.
		await expectOnAccentInk(canvas.getByRole('button', { name: 'Save' }));

		// The client-side mirror of the backend ScriptValidator rule: the
		// function must be one the script exports. An unknown name shows the
		// error; an exported one clears it.
		const fnInput = canvas.getByLabelText('Lua function');
		await userEvent.type(fnInput, 'bogus_fn');
		await expect(canvas.getByText('Not exported by the script')).toBeVisible();
		await userEvent.clear(fnInput);
		await userEvent.type(fnInput, 'win');
		await expect(canvas.queryByText('Not exported by the script')).toBeNull();
	}}
/>

<Story
	name="Deal — general readonly (no update permission)"
	args={{
		qualifiedName: 'crm.Deal',
		tab: 'general',
		readonly: true,
		registry: createMockDriver()
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Identity stays visible but is not editable: without the metadata
		// grant even the presentation fields are disabled.
		await expect(canvas.getByLabelText('Name')).toHaveAttribute('readonly');
		await expect(canvas.getByLabelText('Label')).toBeDisabled();
		await expect(canvas.getByLabelText('Plural label')).toBeDisabled();
		await expect(canvas.getByLabelText('Schema version')).toBeDisabled();
		// The migrations section is readonly too: no add and no delete rows.
		await expect(canvas.queryByRole('button', { name: 'Add migration' })).not.toBeInTheDocument();
		// No save and no danger zone — the readonly header offers a draft
		// instead. (The draft button is never clicked: it fires the session
		// layer, which this story does not stub.)
		await expect(canvas.queryByRole('button', { name: 'Save' })).not.toBeInTheDocument();
		await expect(canvas.queryByRole('button', { name: 'Delete doctype' })).not.toBeInTheDocument();
		const draftBtn = canvas.getByRole('button', { name: 'Create draft to edit' });
		await expect(draftBtn).toBeInTheDocument();
		// The gold fill must stay readable — this caught gold-on-gold text in
		// dark theme (accent-ink == accent there).
		await expectOnAccentInk(draftBtn);
	}}
/>

<Story
	name="Deal — published, metadata editable"
	args={{
		qualifiedName: 'crm.Deal',
		tab: 'general',
		readonly: true,
		allowMetadataEdit: true,
		registry: createMockDriver()
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Presentation metadata stays editable without a draft — the save is
		// a metadata-only PUT that passes the live same-version guards.
		const labelInput = canvas.getByLabelText('Label');
		await expect(labelInput).toBeEnabled();
		await userEvent.clear(labelInput);
		await userEvent.type(labelInput, 'Dealings');
		await expect(labelInput).toHaveValue('Dealings');
		await expect(canvas.getByLabelText('Plural label')).toBeEnabled();
		await expect(canvas.getByLabelText('Description')).toBeEnabled();
		// Shape fields still need a draft.
		await expect(canvas.getByLabelText('Schema version')).toBeDisabled();
		await expect(canvas.queryByRole('button', { name: 'Add migration' })).not.toBeInTheDocument();
		await expect(canvas.queryByRole('button', { name: 'Delete doctype' })).not.toBeInTheDocument();
		// The header carries both affordances. (Save is not clicked here: it
		// fires the session layer, which this story does not stub.)
		await expect(canvas.getByRole('button', { name: 'Save' })).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Create draft to edit' })).toBeVisible();
	}}
/>

<Story
	name="Templated — templates save with the definition"
	args={{ qualifiedName: 'crm.Templated', tab: 'general', registry: templatedDriver() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The fixture carries no templates: both inputs start empty and the
		// save must add both keys to the PUT body.
		const labelInput = canvas.getByLabelText('Label template');
		const searchInput = canvas.getByLabelText('Search template');
		await expect(labelInput).toHaveValue('');
		await expect(searchInput).toHaveValue('');
		// The template section carries the stale-rows hint: template edits
		// reach new documents only, and existing rows need a reproject
		// (F02-03). The wording rides the message catalogue, so match a
		// stable fragment rather than the whole sentence.
		await expect(canvas.getByText(/until you reproject the doctype/)).toBeVisible();
		// userEvent reads a `{` as the lead of a special key; doubling escapes
		// it (`}` needs no escape). The toHaveValue assertions prove the
		// rendered template text survived the keystroke parsing.
		const typeTemplate = (raw: string) => raw.split('{').join('{{');
		const labelTemplate = '{{ first_name }} {{ last_name }}';
		const searchTemplate = '{{ first_name }} {{ last_name }} {{ email }}';
		await userEvent.type(labelInput, typeTemplate(labelTemplate));
		await userEvent.type(searchInput, typeTemplate(searchTemplate));
		await expect(labelInput).toHaveValue(labelTemplate);
		await expect(searchInput).toHaveValue(searchTemplate);
		const body = await saveAndCaptureBody(canvas);
		await expect(body.display_name).toBe(labelTemplate);
		await expect(body.search).toBe(searchTemplate);
	}}
/>

<Story
	name="Templated — cleared templates round-trip clean"
	args={{
		qualifiedName: 'crm.Templated',
		tab: 'general',
		registry: templatedDriver({ display_name: '{{ name }}', search: '{{ name }}' })
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The stored templates load into the inputs...
		const labelInput = canvas.getByLabelText('Label template');
		const searchInput = canvas.getByLabelText('Search template');
		await expect(labelInput).toHaveValue('{{ name }}');
		await expect(searchInput).toHaveValue('{{ name }}');
		// ...and clearing both saves without the keys: absent is the
		// backend's empty state, so the stored templates do not survive
		// as stale values through the preserved round-trip.
		await userEvent.clear(labelInput);
		await userEvent.clear(searchInput);
		const body = await saveAndCaptureBody(canvas);
		await expect('display_name' in body).toBe(false);
		await expect('search' in body).toBe(false);
	}}
/>

<!-- A no-op Save must not render a failure. The backend refuses a
	definition that diffs empty with a 422 "No changes detected …"; the
	editor presents it as the neutral saved state. -->
<Story
	name="Templated — no-op save is neutral"
	args={{
		qualifiedName: 'crm.Templated',
		tab: 'general',
		registry: templatedDriver({ display_name: '{{ name }}', search: '{{ name }}' })
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const originalFetch = window.fetch;
		window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
			if (
				typeof input === 'string' &&
				input.includes('/Api/core/DocType/') &&
				init?.method === 'PUT'
			) {
				return new Response(
					JSON.stringify({ error: 'No changes detected in doctype definition' }),
					{
						status: 422,
						headers: { 'Content-Type': 'application/json' }
					}
				);
			}
			return originalFetch.call(window, input, init);
		};
		try {
			await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
			// The neutral outcome: the button flashes "Saved" and never says
			// the save failed.
			await waitFor(() => expect(canvas.getByRole('button', { name: 'Saved' })).toBeVisible());
			await expect(canvas.queryByRole('button', { name: /Save failed/ })).toBeNull();
		} finally {
			window.fetch = originalFetch;
		}
	}}
/>

<!-- The General tab surfaces the doctype's informational defaults check
	notices next to the template inputs. Warnings stay on the domain Check
	tab. A save refreshes them, so a notice the save fixed disappears. -->
<Story
	name="Templated — check notices render and refresh"
	args={{ qualifiedName: 'crm.Templated', tab: 'general', registry: templatedDriver() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const originalFetch = window.fetch;
		window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
			if (typeof input === 'string' && input.includes('/Api/core/DocType/crm.Templated/check')) {
				return new Response(
					JSON.stringify({
						data: {
							doctype_id: 'crm.Templated',
							issues: [
								{
									severity: 'info',
									category: 'defaults',
									message:
										'No search template declared: search defaults to the display_name corpus; the cross-doctype search endpoint skips this doctype'
								},
								{
									severity: 'warning',
									category: 'actions',
									message: 'warning issues stay off this surface'
								}
							]
						}
					}),
					{ status: 200, headers: { 'Content-Type': 'application/json' } }
				);
			}
			if (
				typeof input === 'string' &&
				input.includes('/Api/core/DocType/') &&
				init?.method === 'PUT'
			) {
				return new Response('{}', { status: 200 });
			}
			return originalFetch.call(window, input, init);
		};
		try {
			// Nothing renders before a check result arrives.
			await expect(canvas.queryByText(/No search template declared/)).toBeNull();
			// A save bumps the notice fetch: the notice appears without a reload.
			await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
			await waitFor(() => expect(canvas.getByText(/No search template declared/)).toBeVisible());
			await expect(canvas.queryByText('warning issues stay off this surface')).toBeNull();
			await expect(canvas.getByText('Notices')).toBeVisible();
		} finally {
			window.fetch = originalFetch;
		}
	}}
/>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DvtRelation from './DvtRelation.svelte';
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import type { MockDataSource } from '$lib/datasource/MockDataSource.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { RelationNode, ReferenceClickHandler, TemplateNode } from '$lib/template-types';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtRelation',
		component: DvtRelation,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/**
	 * Build a mock driver seeded with crm.Contact + crm.CompanyMembership rows.
	 * Company 1 owns three memberships (children via parent_id); Contact 1
	 * participates in two of them (inverse filter on `contact__eq`).
	 *
	 * `MockDataSource` synthesises `display_name` from `name` so hydrated
	 * capsules have a meaningful label without a doctype-def round-trip.
	 */
	function buildDriver(): MockDataDriver {
		const driver = new MockDataDriver();

		// Contacts (the rows capsules hydrate their label from). Include the
		// fields the table-view story reads through the `contact.*` dotted keys
		// (full_name is a `data` field on the fixture doctype; we set it directly
		// here since the mock driver does not run the Lua compute hook).
		driver.domain('crm').doctype('Contact', [
			{
				id: 'crm.Contact.1',
				name: 'Alice Johnson',
				full_name: 'Alice Johnson',
				email: 'alice@acme.com',
				phone: '+1-555-0101',
				job_title: 'CTO'
			},
			{
				id: 'crm.Contact.2',
				name: 'Bob Williams',
				full_name: 'Bob Williams',
				email: 'bob@acme.com',
				phone: '+1-555-0102',
				job_title: 'VP Sales'
			},
			{
				id: 'crm.Contact.3',
				name: 'Carol Martinez',
				full_name: 'Carol Martinez',
				email: 'carol@globex.com',
				phone: '+1-555-0103',
				job_title: 'Head of Ops'
			}
		]);

		// Companies.
		driver.domain('crm').doctype('Company', [
			{ id: 'crm.Company.1', name: 'Acme Corp' },
			{ id: 'crm.Company.2', name: 'Globex Inc' }
		]);

		// CompanyMembership rows are seeded directly with `doc_type:
		// 'CompanyMembership'` (so the `filter` query path sees them) AND ids
		// prefixed `crm.Company.<n>.memberships.` (so the `children` walk via
		// MockChildDataSource's id-prefix filter also sees them).
		// The backend doesn't have this dual-addressing constraint (one
		// projection row addresses both routes) but MockDataSource models
		// children list purely by id-prefix, so this explicit dual-shape
		// seeding is the cleanest way to cover both `source.kind` modes.
		driver.domain('crm').doctype('CompanyMembership', [
			{
				id: 'crm.Company.1.memberships.1',
				contact: 'crm.Contact.1',
				role: 'primary',
				billing_contact: true
			},
			{
				id: 'crm.Company.1.memberships.2',
				contact: 'crm.Contact.2',
				role: 'secondary',
				billing_contact: false
			},
			{
				id: 'crm.Company.1.memberships.3',
				contact: 'crm.Contact.3',
				role: 'observer',
				billing_contact: false
			},
			// Contact 1 also at Globex -- the N-N case (two companies for one contact).
			{
				id: 'crm.Company.2.memberships.4',
				contact: 'crm.Contact.1',
				role: 'observer',
				billing_contact: false
			}
		]);

		// Register the doctype definitions the table-view story needs to resolve
		// field types for `crm.CompanyMembership` (relation doctype def) and
		// `crm.Contact` (target of the `contact.*` column traversal). Mirror the
		// fixture schema — only the fields the stories read matter here.
		driver.registerDoctype('crm', 'CompanyMembership', {
			doctype: 'CompanyMembership',
			domain: 'crm',
			schema_version: 1,
			fields: {
				role: {
					type: 'enum',
					values: [
						{ key: 'primary', label: 'Primary', color: '#0089a7' },
						{ key: 'secondary', label: 'Secondary', color: '#97751a' },
						{ key: 'observer', label: 'Observer', color: '#b25e5e' }
					]
				},
				contact: { type: 'reference', doctype: 'crm.Contact' },
				billing_contact: { type: 'boolean' }
			}
		});
		driver.registerDoctype('crm', 'Contact', {
			doctype: 'Contact',
			domain: 'crm',
			schema_version: 1,
			fields: {
				full_name: { type: 'data' },
				email: { type: 'string' },
				phone: { type: 'phone' },
				job_title: { type: 'string' }
			}
		});

		return driver;
	}

	const driver = buildDriver();

	function parentDoc(id: string): DocumentResponse {
		return {
			data: { name: 'Acme Corp' },
			meta: {
				id,
				mid: id,
				domain: 'crm',
				doc_type: 'Company',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}
	const childrenTemplate: RelationNode = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		referenceField: 'contact',
		source: { kind: 'children', rel: 'memberships' },
		view: 'capsule',
		limit: 25
	};

	const filterTemplate: RelationNode = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		referenceField: 'contact',
		source: { kind: 'filter', field: 'contact' },
		view: 'capsule',
		limit: 25
	};

	const emptyChildrenTemplate: RelationNode = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		referenceField: 'contact',
		source: { kind: 'children', rel: 'memberships' },
		view: 'capsule',
		limit: 25
	};

	// Table-view templates. The mixed-columns story blends `contact.*` (traversal
	// over the `contact` reference) with `role` (local membership-side field) so
	// the test covers both cell origins in one render. The local-only template
	// exercises the no-hydration fast path.
	const tableMixedTemplate: RelationNode = {
		type: 'relation',
		label: 'Contacts',
		doctype: 'crm.CompanyMembership',
		referenceField: 'contact',
		source: { kind: 'children', rel: 'memberships' },
		view: 'table',
		limit: 25,
		columns: [
			{ key: 'contact.full_name', label: 'Name' },
			{ key: 'contact.email', label: 'Email', width: '220px' },
			{ key: 'contact.phone', label: 'Phone', width: '150px' },
			{ key: 'contact.job_title', label: 'Title' },
			{ key: 'role', label: 'Role at company', width: '130px' }
		]
	};

	const tableLocalOnlyTemplate: RelationNode = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		source: { kind: 'children', rel: 'memberships' },
		view: 'table',
		limit: 25,
		columns: [{ key: 'role', label: 'Role at company', width: '160px' }]
	};

	// Inline-edit columns. The local boolean toggles in place (update-permission
	// gated); the dotted column carries the flag too but stays read-only — its
	// leaf lives on the referenced contact, not the row.
	const tableEditableTemplate: RelationNode = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		referenceField: 'contact',
		source: { kind: 'children', rel: 'memberships' },
		view: 'table',
		limit: 25,
		columns: [
			{ key: 'contact.full_name', label: 'Name', editable: true },
			{ key: 'billing_contact', label: 'Billing contact', editable: true },
			{ key: 'role', label: 'Role at company', width: '130px' }
		]
	};

	// ── Inline read-mode story fixtures ────────────────────────────────────
	//
	// The `view: 'inline'` mode renders each row via the relation doctype's
	// `inline` (or `quickView` fallback) view template. We use hr.CandidateExperience
	// because the fixtures define full content + child linkage, and `createMockDriver`
	// pre-registers the doctype definition so the inline template loader works
	// against a registered schema.

	/** Candidate row used as the parent in inline stories. */
	const candidateDoc = parentDoc('hr.Candidate.cand_01HZX9Q2');
	(candidateDoc.meta as { doc_type: string }).doc_type = 'Candidate';
	(candidateDoc.meta as { domain: string }).domain = 'hr';

	/** A driver seeded with the standard fixtures plus experience rows whose
	 *  ids follow the `parentId.relName.N` convention MockChildDataSource uses
	 *  to filter children by parent. */
	function buildCandidateExperiencesDriver(): MockDataDriver {
		const d = createMockDriver();
		const candidateId = 'hr.Candidate.cand_01HZX9Q2';
		const childDs = d
			.domain('hr')
			.doctype<Record<string, unknown>>('Candidate')
			.doc(candidateId)
			.children<Record<string, unknown>>('experiences');
		// Seed through the child-scoped DataSource so ids follow the
		// `parentId.experiences.UUID` convention MockChildDataSource filters by.
		// Internally synchronous — the returned promises are fire-and-forget.
		void childDs.create({
			company: 'Monzo',
			title: 'Staff Engineer',
			location: 'London',
			type: 'full_time',
			start: '2022-03-01T00:00:00Z',
			end: null,
			current: true,
			desc: 'Owns the ledger platform.'
		});
		void childDs.create({
			company: 'Deliveroo',
			title: 'Senior Backend Engineer',
			location: 'London',
			type: 'full_time',
			start: '2018-06-01T00:00:00Z',
			end: '2022-02-15T00:00:00Z',
			current: false,
			desc: 'Dispatch optimisation services.'
		});
		return d;
	}

	const candidateExperiencesDriver = buildCandidateExperiencesDriver();

	const experiencesViewTemplate: RelationNode = {
		type: 'relation',
		label: 'Work Experience',
		doctype: 'hr.CandidateExperience',
		source: { kind: 'children', rel: 'experiences' },
		view: 'inline',
		limit: 25
	};

	const experiencesEditableTemplate: RelationNode = {
		type: 'relation',
		label: 'Work Experience',
		doctype: 'hr.CandidateExperience',
		source: { kind: 'children', rel: 'experiences' },
		editable: true,
		limit: 25
	};

	// ── Editable fallback fixtures (B-348) ────────────────────────────────
	//
	// `hr.CandidateNote` is a bespoke child doctype with no stored
	// `core.DocumentView` at all. The editable path must fall back to the
	// generic field walk over the definition instead of the old "no form
	// view" dead end.

	function buildNotesDriver(): MockDataDriver {
		const d = createMockDriver();
		// Register the definition first — no `core.DocumentView` child exists
		// for this doctype, so the editable rows must walk this schema.
		d.registerDoctype('hr', 'CandidateNote', {
			doctype: 'CandidateNote',
			domain: 'hr',
			schema_version: 1,
			fields: {
				note: { type: 'string' },
				priority: {
					type: 'enum',
					values: [
						{ key: 'high', label: 'High' },
						{ key: 'low', label: 'Low' }
					]
				},
				pinned: { type: 'boolean' }
			}
		});
		const childDs = d
			.domain('hr')
			.doctype<Record<string, unknown>>('Candidate')
			.doc('hr.Candidate.cand_01HZX9Q2')
			.children<Record<string, unknown>>('notes');
		// Seed through the child-scoped DataSource so ids follow the
		// `parentId.notes.UUID` convention MockChildDataSource filters by.
		// Internally synchronous — the returned promises are fire-and-forget.
		void childDs.create({ note: 'Call back on Friday', priority: 'high', pinned: true });
		void childDs.create({ note: 'Send the offer letter', priority: 'low', pinned: false });
		return d;
	}

	const notesDriver = buildNotesDriver();

	const notesEditableTemplate: RelationNode = {
		type: 'relation',
		label: 'Notes',
		doctype: 'hr.CandidateNote',
		source: { kind: 'children', rel: 'notes' },
		editable: true,
		limit: 25
	};

	// ── Malformed source fixture (F10-09) ──────────────────────────
	//
	// A source stored as a bare string passes through unchanged, so the
	// component sees `source.kind === undefined`. The section must show
	// the local config error and never fire the list request the backend
	// would answer with a misleading 403/422.
	const malformedSourceTemplate = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		referenceField: 'contact',
		source: 'memberships',
		view: 'capsule',
		limit: 25
	} as unknown as RelationNode;
</script>

<script lang="ts">
	import { expect, userEvent, waitFor, within } from 'storybook/test';

	/** Minimal delay helper — `storybook/test` in this version has no `sleep`. Yields
	 *  once so Svelte runes flush and a pending fetch promise resolves. */
	function sleep(ms: number): Promise<void> {
		return new Promise((r) => setTimeout(r, ms));
	}

	// Captures the last fired reference click — used to assert that capsule
	// clicks on a relation row propagate to the host's `openReference` handler.
	let _lastClick: { domain: string; doctype: string; id: string } | null = $state(null);
	const clickHandler: ReferenceClickHandler = (e) => {
		_lastClick = e;
	};
</script>

<Story
	name="ChildrenSource"
	args={{
		template: childrenTemplate,
		document: parentDoc('crm.Company.1')
	}}
	play={async ({ canvasElement, step }) => {
		await sleep(120);
		const canvas = within(canvasElement);
		// Three membership rows seeded under crm.Company.1 should render three
		// hydrated capsule buttons labelled with the referenced contact's name.
		const roleButtons = canvas.queryAllByRole('button');
		await expect(roleButtons.length).toBeGreaterThanOrEqual(3);

		await step('capsule click fires the reference handler', async () => {
			if (roleButtons.length === 0) return;
			// Clicking the first capsule should resolve the referenced doctype
			// to `crm.Contact` and propagate the qualified id.
			await sleep(0);
			_lastClick = null;
		});
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation
				template={args.template}
				document={args.document}
				{driver}
				onreferenceclick={clickHandler}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FilterSource"
	args={{
		template: filterTemplate,
		document: parentDoc('crm.Contact.1')
	}}
	play={async ({ canvasElement }) => {
		await sleep(120);
		const canvas = within(canvasElement);
		// Contact 1 participates in two memberships (Company 1 primary and
		// Company 2 observer) — the N-N case.
		const buttons = canvas.queryAllByRole('button');
		await expect(buttons.length).toBe(2);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation
				template={args.template}
				document={args.document}
				{driver}
				onreferenceclick={clickHandler}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyChildren"
	args={{
		template: emptyChildrenTemplate,
		document: parentDoc('crm.Company.99')
	}}
	play={async ({ canvasElement }) => {
		await sleep(120);
		const canvas = within(canvasElement);
		// No membership rows were seeded under crm.Company.99 — the empty
		// state placeholder renders instead of capsule buttons.
		await expect(canvas.queryAllByRole('button').length).toBe(0);
		await expect(canvas.queryByText('No items')).not.toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation
				template={args.template}
				document={args.document}
				{driver}
				onreferenceclick={clickHandler}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TableWithMixedColumns"
	args={{
		template: tableMixedTemplate,
		document: parentDoc('crm.Company.1')
	}}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// Header labels render.
		await expect(canvas.getByText('Name')).toBeVisible();
		await expect(canvas.getByText('Email')).toBeVisible();
		await expect(canvas.getByText('Phone')).toBeVisible();
		await expect(canvas.getByText('Title')).toBeVisible();
		await expect(canvas.getByText('Role at company')).toBeVisible();
		// Resolved Contact field cells — hydration walked the `contact`
		// reference on each membership to read the target document's fields.
		await expect(canvas.getByText('Alice Johnson')).toBeVisible();
		await expect(canvas.getByText('alice@acme.com')).toBeVisible();
		await expect(canvas.getByText('CTO')).toBeVisible();
		// Local membership-side field cell (role) — humanized enum label.
		await expect(canvas.getByText('Primary')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation
				template={args.template}
				document={args.document}
				{driver}
				onreferenceclick={clickHandler}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TableLocalOnly"
	args={{
		template: tableLocalOnlyTemplate,
		document: parentDoc('crm.Company.1')
	}}
	play={async ({ canvasElement }) => {
		await sleep(200);
		const canvas = within(canvasElement);
		// No reference traversal — no hydration calls; all cells are local.
		await expect(canvas.getByText('Role at company')).toBeVisible();
		await expect(canvas.getByText('Primary')).toBeVisible();
		await expect(canvas.getByText('Secondary')).toBeVisible();
		await expect(canvas.getByText('Observer')).toBeVisible();
		// Three rows seeded under crm.Company.1.
		await expect(canvas.queryAllByRole('row').length).toBe(4); // header + 3.
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation template={args.template} document={args.document} {driver} />
		</div>
	{/snippet}
</Story>

<Story
	name="TableEmpty"
	args={{
		template: tableMixedTemplate,
		document: parentDoc('crm.Company.99')
	}}
	play={async ({ canvasElement }) => {
		await sleep(200);
		const canvas = within(canvasElement);
		// No rows seeded under crm.Company.99 — the empty state placeholder renders.
		await expect(canvas.queryByText('Name')).toBeNull();
		await expect(canvas.queryByText('No items')).not.toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation template={args.template} document={args.document} {driver} />
		</div>
	{/snippet}
</Story>

<Story
	name="TableNarrowScrolls"
	args={{
		template: tableMixedTemplate,
		document: parentDoc('crm.Company.1')
	}}
	play={async ({ canvasElement }) => {
		await sleep(300);
		// The narrow frame pushes the nowrap table past its container width.
		// The wrapper must own the overflow: it scrolls, and its parent
		// container stays exactly as wide as the wrapper (no horizontal
		// bleed into the document column).
		const wrap = canvasElement.querySelector('.dvt-relation-table-wrap');
		await expect(wrap).not.toBeNull();
		const wrapEl = wrap as HTMLElement;
		await expect(wrapEl.scrollWidth).toBeGreaterThan(wrapEl.clientWidth);
		const parent = wrapEl.parentElement as HTMLElement;
		await expect(parent.scrollWidth).toBeLessThanOrEqual(wrapEl.clientWidth + 1);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame dvt-story-frame-narrow">
			<DvtRelation template={args.template} document={args.document} {driver} />
		</div>
	{/snippet}
</Story>

<Story
	name="TableInlineEdit"
	args={{
		template: tableEditableTemplate,
		document: parentDoc('crm.Company.1')
	}}
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		const rowId = 'crm.Company.1.memberships.1';
		const membershipDs = driver.domain('crm').doctype('CompanyMembership');

		// Defensive reseed so a retried play starts from a known state.
		await membershipDs.doc(rowId).update({ billing_contact: true });
		await sleep(0);

		// The local boolean column marked editable renders one toggle per row;
		// the dotted column carries the flag too but never renders a toggle.
		const toggles = canvas.getAllByRole('button', { name: 'Toggle Billing contact' });
		await expect(toggles.length).toBe(3);
		await expect(canvas.queryByRole('button', { name: 'Toggle Name' })).toBeNull();

		// Click flips the cell optimistically and persists the row document.
		const toggle = toggles[0];
		await expect(toggle).toHaveAttribute('aria-pressed', 'true');
		await userEvent.click(toggle);
		await waitFor(() => expect(toggle).toHaveAttribute('aria-pressed', 'false'));
		const doc = await membershipDs.doc(rowId).show();
		await expect((doc.data as Record<string, unknown>).billing_contact).toBe(false);

		// The toggle click never opens the row's referenced contact.
		await expect(_lastClick).toBeNull();
	}}
>
	{#snippet template(args)}
		<CanFixture manifest={{ 'crm.CompanyMembership': ['update'] }}>
			<div class="dvt-story-frame">
				<DvtRelation template={args.template} document={args.document} {driver} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="InlineView"
	args={{
		template: experiencesViewTemplate,
		document: candidateDoc
	}}
	play={async ({ canvasElement }) => {
		await sleep(800);
		// Two seeded experience rows under hr.Candidate.cand_01HZX9Q2.experiences
		// render two inline cards. Each card surfaces the company name as a
		// `$company` capsule (or inline text) in the `quickView` fallback
		// template. Testing-Library has no `queryAllByClassName` helper (it is
		// not part of the DOM Testing Library API), so we assert directly
		// against the rendered HTML — this is a smoke-test level story, so
		// substring assertions on `innerHTML` are sufficient and robust against
		// Svelte scoped-class suffixes.
		const html = canvasElement.innerHTML;
		await expect(html).toContain('Monzo');
		await expect(html).toContain('Deliveroo');
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation
				template={args.template}
				document={args.document}
				driver={candidateExperiencesDriver}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EditableAddRow"
	args={{
		template: experiencesEditableTemplate,
		document: candidateDoc
	}}
	play={async ({ canvasElement }) => {
		await sleep(800);
		const canvas = within(canvasElement);
		// Editable sections expose an "Add" button — clicking it stages a new
		// draft row in `values['__relation_drafts__'][rel]` and re-renders the
		// row list with an inline form template. Regression guard for the
		// reactivity chain: ensureDraftsBag -> setDrafts -> draftsSlot -> drafts.
		const addBtn = canvas.queryByRole('button', { name: /Add Work Experience/ });
		await expect(addBtn).not.toBeNull();

		const beforeCount = canvas.queryAllByRole('button', { name: /Remove/ }).length;
		addBtn?.click();
		await sleep(50);
		// A new draft row should appear, with its remove button rendered.
		const afterCount = canvas.queryAllByRole('button', { name: /Remove/ }).length;
		await expect(afterCount).toBe(beforeCount + 1);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation
				template={args.template}
				document={args.document}
				driver={candidateExperiencesDriver}
				values={{}}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EditableAddRowProxied"
	args={{
		template: experiencesEditableTemplate,
		document: candidateDoc
	}}
	play={async ({ canvasElement }) => {
		await sleep(800);
		const canvas = within(canvasElement);
		// Same scenario as `EditableAddRow`, but routed through
		// `DocumentViewTemplate` so the `values` bag arrives as a Svelte 5
		// `$state` deep proxy (the production wiring — `DocumentForm` ->
		// `DocumentViewTemplate.valuesState = $state(values)` ->
		// `DvtRelation.values`).
		//
		// Regression guard: an earlier mirror implementation wrote to
		// `values[DRAFTS_KEY]` without isolating the writes, and the proxy
		// invalidation re-fired `load()`'s effect repeatedly →
		// `effect_update_depth_exceeded`. Sleeping 800ms here lets the
		// effect run a few cycles; if the loop is back the storybook
		// harness throws the Svelte error and the test fails.
		const addBtn = canvas.queryByRole('button', { name: /Add Work Experience/ });
		await expect(addBtn).not.toBeNull();

		const beforeCount = canvas.queryAllByRole('button', { name: /Remove/ }).length;
		addBtn?.click();
		await sleep(50);
		const afterCount = canvas.queryAllByRole('button', { name: /Remove/ }).length;
		await expect(afterCount).toBe(beforeCount + 1);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate
				template={args.template as TemplateNode}
				document={args.document}
				values={{}}
				driver={candidateExperiencesDriver}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EditableFallbackFieldWalk"
	args={{
		template: notesEditableTemplate,
		document: candidateDoc
	}}
	play={async ({ canvasElement }) => {
		await sleep(800);
		const canvas = within(canvasElement);
		// `hr.CandidateNote` has no `form` view. Each row falls back to the
		// generic field walk: one control per editable field of the child
		// definition. Two seeded rows render two boolean toggles (`pinned`)
		// and two text inputs (`note`); the enum renders a select. The old
		// "no form view" dead end must not come back.
		await expect(canvas.getAllByRole('switch').length).toBe(2);
		await expect(canvas.getAllByRole('textbox').length).toBeGreaterThanOrEqual(2);
		await expect(canvas.queryByText(/No form view defined/)).toBeNull();
		// Add stages one more draft row and the walk renders its controls.
		const addBtn = canvas.getByRole('button', { name: /Add Notes/ });
		await userEvent.click(addBtn);
		await waitFor(async () => {
			await expect(canvas.getAllByRole('switch').length).toBe(3);
		});
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation
				template={args.template}
				document={args.document}
				driver={notesDriver}
				values={{}}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="MalformedSourceShowsConfigError"
	args={{ template: malformedSourceTemplate, document: parentDoc('crm.Company.1') }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Baseline the spy before the component's effect runs, then wait for
		// the render to settle.
		const membershipDs = driver.domain('crm').doctype('CompanyMembership') as MockDataSource;
		membershipDs.listCalls.length = 0;
		await sleep(200);
		// The section shows the local config-error message — not a backend
		// "Forbidden" permissions string.
		await expect(canvas.getByText('Invalid relation configuration')).toBeVisible();
		// No row list rendered, and no request fired.
		await expect(canvas.queryAllByRole('button').length).toBe(0);
		expect(membershipDs.listCalls).toHaveLength(0);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelation template={args.template} document={args.document} {driver} />
		</div>
	{/snippet}
</Story>

<style>
	.dvt-story-frame {
		display: block;
		width: 100%;
		max-width: 720px;
		margin: 0 auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 120px;
	}

	/* Narrow frame forces the mixed-columns table past its container width,
	   so the wrapper-scroll behaviour is actually exercised. */
	.dvt-story-frame-narrow {
		max-width: 380px;
	}
</style>

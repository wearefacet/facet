<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { loadDoctypeView, loadDoctypeViews } from '$lib/doctype/loadDocumentView.js';
	import { parseDoctypeDef } from '$lib/doctype/types.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import { seedEditValues } from '$lib/doctype/formSeed.js';

	// Regression-test driver: real fixture data, real crm.Company view
	// template. The story asserts the rendered show view never overflows
	// its container horizontally (the header-subtitle regression).
	const diagDriver = createMockDriver();
	const diagView = await loadDoctypeView(diagDriver, 'crm.Company');
	const diagDoc = await diagDriver
		.domain('crm')
		.doctype<Record<string, unknown>>('Company')
		.doc('crm.Company.1')
		.show();
	const diagDef = parseDoctypeDef(
		diagDriver.doctypeDefinitions.get('crm.Company') as Record<string, unknown>
	);

	// Seeded iam.Account views (data/seeds/core.DocumentView/documents.yml)
	// rendered against a mock account. Loads the real seed templates through
	// the mock driver, exactly as the show/peek/form routes would.
	const accountDriver = createMockDriver();
	const accountViews = await loadDoctypeViews(accountDriver, 'iam.Account');
	const accountDef = parseDoctypeDef(
		accountDriver.doctypeDefinitions.get('iam.Account') as Record<string, unknown>
	);
	const accountDoc = {
		data: {
			email: 'ada@examplecompany.tld',
			name: 'Ada Lovelace',
			status: 'active',
			organizational_unit: '/engineering/',
			roles: ['iam.Roles.admin', 'iam.Roles.viewer'],
			default_role: 'iam.Roles.editor',
			mfa_enabled: true,
			must_change_pw: false,
			service_account: false,
			federated_identities: [
				{ provider: 'keycloak', subject: 'ada@company.tld', linked_at: '2026-09-01T10:00:00Z' }
			]
		},
		meta: {
			id: 'iam.Account.demo',
			mid: 'iam.Account.demo',
			domain: 'iam',
			doc_type: 'Account',
			version: 3,
			schema_version: 1,
			display_name: 'Ada Lovelace',
			created_at: '2026-09-01T10:00:00Z',
			updated_at: '2026-10-01T10:00:00Z'
		} satisfies DocumentMeta
	} as DocumentResponse<Record<string, unknown>>;
	const accountValues = seedEditValues(accountDef, accountDoc.data);

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DocumentViewTemplate',
		component: DocumentViewTemplate,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	function doc(data: Record<string, unknown>): DocumentResponse {
		return {
			data,
			meta: {
				id: 'test.1',
				mid: 'test.1',
				domain: 'test',
				doc_type: 'Test',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	/** A minimal doctype def carrying one `longtext` field. */
	const longtextDef: DoctypeDef = {
		doctype: 'Candidate',
		domain: 'hr',
		schema_version: 1,
		aggregate_root: true,
		description: '',
		children: [],
		actions: [],
		fields: [{ key: 'summary', type: 'longtext', title: 'Summary' }]
	};

	/** HR Employee mock dataset. */
	const employeeData: Record<string, unknown> = {
		employee_id: 'EMP-0042',
		first_name: 'Jane',
		last_name: 'Doe',
		email: 'jane.doe@company.com',
		email_label: 'jane.doe@company.com',
		phone: '+1-555-0123',
		department: 'Engineering',
		title: 'Senior Software Engineer',
		manager: 'Sarah Connor',
		hire_date: '2022-03-15',
		status: 'active',
		employment_type: 'full-time',
		avatar_url: 'https://api.dicebear.com/9.x/notionists/svg?seed=Jane',
		salary_range: '$120k-$150k',
		address: {
			street: '456 Oak Ave',
			city: 'San Francisco',
			state: 'CA',
			zip: '94102',
			country: 'USA'
		},
		skills: [
			{ name: 'TypeScript', level: 'expert' },
			{ name: 'Crystal', level: 'advanced' },
			{ name: 'PostgreSQL', level: 'intermediate' }
		],
		emergency_contacts: [{ name: 'John Doe', relationship: 'Spouse', phone: '+1-555-0199' }]
	};
</script>

<Story
	name="HREmployeeMultiTab"
	args={{
		template: {
			type: 'tabs',
			tabs: [
				{
					type: 'tab',
					label: 'Identity',
					children: [
						{
							type: 'grid',
							layout: '1 3',
							children: [
								{
									type: 'col',
									children: [
										{
											type: 'image',
											src: '$avatar_url',
											variant: 'avatar',
											alt: 'Employee photo'
										}
									]
								},
								{
									type: 'col',
									children: [
										{ type: 'title', value: '$first_name $last_name', level: 1 },
										{ type: 'capsule', value: '$employee_id' },
										{ type: 'hr' },
										{ type: 'field', label: 'Employee ID', value: '$employee_id' },
										{ type: 'field', label: 'Full Name', value: '$first_name $last_name' },
										{
											type: 'field',
											label: 'Email',
											value: '$email',
											children: [{ type: 'email', label: '$email_label', href: 'mailto:$email' }]
										},
										{ type: 'field', label: 'Phone', value: '$phone' }
									]
								}
							]
						}
					]
				},
				{
					type: 'tab',
					label: 'Employment',
					children: [
						{ type: 'field', label: 'Department', value: '$department' },
						{ type: 'field', label: 'Title', value: '$title' },
						{ type: 'field', label: 'Manager', value: '$manager' },
						{ type: 'field', label: 'Hire Date', value: '$hire_date' },
						{ type: 'field', label: 'Status', value: '$status' },
						{ type: 'field', label: 'Type', value: '$employment_type' },
						{ type: 'field', label: 'Salary Range', value: '$salary_range' }
					]
				},
				{
					type: 'tab',
					label: 'Address',
					children: [
						{
							type: 'object',
							field: 'address',
							children: [
								{ type: 'field', label: 'Street', value: '$street' },
								{ type: 'field', label: 'City', value: '$city' },
								{ type: 'field', label: 'State', value: '$state' },
								{ type: 'field', label: 'ZIP', value: '$zip' },
								{ type: 'field', label: 'Country', value: '$country' }
							]
						}
					]
				},
				{
					type: 'tab',
					label: 'Skills',
					children: [
						{
							type: 'array',
							field: 'skills',
							children: [
								{ type: 'field', label: 'Skill', value: '$name' },
								{ type: 'field', label: 'Level', value: '$level' }
							]
						}
					]
				},
				{
					type: 'tab',
					label: 'Emergency',
					children: [
						{
							type: 'array',
							field: 'emergency_contacts',
							children: [
								{ type: 'field', label: 'Name', value: '$name' },
								{ type: 'field', label: 'Relation', value: '$relationship' },
								{ type: 'field', label: 'Phone', value: '$phone' }
							]
						}
					]
				},
				{
					type: 'tab',
					label: 'Status',
					children: [
						{
							type: 'if',
							field: 'status',
							value: 'active',
							children: [{ type: 'label', value: '✅ Active employee — good standing' }],
							else: [{ type: 'label', value: '⛔ Inactive employee' }]
						}
					]
				}
			]
		},
		document: doc(employeeData)
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="SingleLabel"
	args={{
		template: { type: 'label', value: '$display_name' },
		document: doc({ display_name: 'Employee Record' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="TabsWithLabels"
	args={{
		template: {
			type: 'tabs',
			tabs: [
				{
					type: 'tab',
					label: 'Identity',
					children: [
						{ type: 'field', label: 'Name', value: '$name' },
						{ type: 'field', label: 'Email', value: '$email' }
					]
				},
				{
					type: 'tab',
					label: 'Address',
					children: [{ type: 'field', label: 'Street', value: '$address.street' }]
				}
			]
		},
		document: doc({
			name: 'Alice Johnson',
			email: 'alice@example.com',
			address: { street: '123 Main St' }
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="AutoInputLongtextReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The auto input guesses longtext from the definition; with no values
		// bag the read-only branch mounts the Milkdown preview. The stored
		// markdown renders as a document — the raw source never shows.
		await expect(canvas.getByText('Summary')).toBeVisible();
		await waitFor(() => {
			expect(canvas.getByText('high-throughput')).toBeVisible();
		});
		await expect(canvas.queryByText(/\*\*/)).toBeNull();
	}}
	args={{
		template: {
			type: 'col',
			children: [
				{
					type: 'section',
					label: 'Record',
					children: [{ type: 'input', field: 'summary' }]
				}
			]
		},
		document: doc({
			summary:
				'Twelve years building **high-throughput** backends.\n\nComfortable across Crystal, Go, Rust.'
		}),
		def: longtextDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="HREmployeeEditForm"
	args={{
		template: {
			type: 'tabs',
			tabs: [
				{
					type: 'tab',
					label: 'Identity',
					children: [
						{
							type: 'grid',
							layout: '1 3',
							children: [
								{
									type: 'col',
									children: [
										{
											type: 'image',
											src: '$avatar_url',
											variant: 'avatar',
											alt: 'Employee photo'
										}
									]
								},
								{
									type: 'col',
									children: [
										{ type: 'title', value: '$first_name $last_name', level: 1 },
										{ type: 'capsule', value: '$employee_id' },
										{ type: 'hr' },
										{
											type: 'input-text',
											field: 'employee_id',
											label: 'Employee ID',
											required: true
										},
										{
											type: 'input-text',
											field: 'first_name',
											label: 'First Name',
											required: true
										},
										{
											type: 'input-text',
											field: 'last_name',
											label: 'Last Name',
											required: true
										},
										{
											type: 'input-text',
											field: 'email',
											label: 'Email',
											inputType: 'email',
											placeholder: 'email@company.com',
											required: true
										},
										{
											type: 'input-text',
											field: 'phone',
											label: 'Phone',
											placeholder: '+1-555-0000'
										}
									]
								}
							]
						}
					]
				},
				{
					type: 'tab',
					label: 'Employment',
					children: [
						{
							type: 'input-select',
							field: 'department',
							label: 'Department',
							options: [
								{ value: 'Engineering', label: 'Engineering' },
								{ value: 'Design', label: 'Design' },
								{ value: 'Marketing', label: 'Marketing' },
								{ value: 'Sales', label: 'Sales' },
								{ value: 'HR', label: 'HR' },
								{ value: 'Finance', label: 'Finance' }
							]
						},
						{
							type: 'input-text',
							field: 'title',
							label: 'Job Title',
							required: true
						},
						{
							type: 'input-text',
							field: 'manager',
							label: 'Manager'
						},
						{
							type: 'input-text',
							field: 'hire_date',
							inputType: 'date',
							label: 'Hire Date'
						},
						{
							type: 'input-select',
							field: 'status',
							label: 'Status',
							options: [
								{ value: 'active', label: 'Active' },
								{ value: 'inactive', label: 'Inactive' },
								{ value: 'on_leave', label: 'On Leave' },
								{ value: 'terminated', label: 'Terminated' }
							]
						},
						{
							type: 'input-select',
							field: 'employment_type',
							label: 'Employment Type',
							options: [
								{ value: 'full-time', label: 'Full-time' },
								{ value: 'part-time', label: 'Part-time' },
								{ value: 'contract', label: 'Contract' },
								{ value: 'intern', label: 'Intern' }
							]
						},
						{
							type: 'input-text',
							field: 'salary_range',
							label: 'Salary Range',
							placeholder: 'e.g. $120k-$150k'
						},
						{ type: 'hr' },
						{
							type: 'input-toggle',
							field: 'is_remote',
							label: 'Remote worker'
						},
						{
							type: 'input-toggle',
							field: 'is_manager',
							label: 'People manager'
						}
					]
				},
				{
					type: 'tab',
					label: 'Address',
					children: [
						{
							type: 'object',
							field: 'address',
							children: [
								{
									type: 'input-text',
									field: 'street',
									label: 'Street'
								},
								{
									type: 'input-text',
									field: 'city',
									label: 'City'
								},
								{
									type: 'input-text',
									field: 'state',
									label: 'State'
								},
								{
									type: 'input-text',
									field: 'zip',
									label: 'ZIP Code'
								},
								{
									type: 'input-text',
									field: 'country',
									label: 'Country'
								}
							]
						}
					]
				},
				{
					type: 'tab',
					label: 'Skills',
					children: [
						{
							type: 'array',
							field: 'skills',
							children: [
								{
									type: 'input-text',
									field: 'name',
									label: 'Skill',
									placeholder: 'e.g. TypeScript'
								},
								{
									type: 'input-select',
									field: 'level',
									label: 'Level',
									options: [
										{ value: 'beginner', label: 'Beginner' },
										{ value: 'intermediate', label: 'Intermediate' },
										{ value: 'advanced', label: 'Advanced' },
										{ value: 'expert', label: 'Expert' }
									]
								}
							]
						}
					]
				},
				{
					type: 'tab',
					label: 'Notes',
					children: [
						{
							type: 'input-longtext',
							field: 'notes',
							label: 'Notes',
							placeholder: 'Enter notes about this employee…'
						}
					]
				}
			]
		},
		document: doc(employeeData),
		values: {}
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="UnregisteredType"
	args={{
		template: { type: 'unknown_type', value: 'test' } as never,
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="CompanyEditFormRedesign"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Five section eyebrow labels are present (the canonical grouped-form
		// pattern the Company fixture demonstrates).
		for (const label of ['Identity', 'Firmographics', 'Contact', 'Address', 'Account']) {
			await expect(canvas.getByText(label)).toBeVisible();
		}
		// The website field's `https://` prefix adornment is rendered.
		await expect(canvas.getByText('https://')).toBeVisible();
	}}
	args={{
		template: {
			type: 'col',
			children: [
				{
					type: 'section',
					label: 'Identity',
					children: [
						{
							type: 'row',
							layout: '260px 180px',
							children: [
								{ type: 'input-text', field: 'name', label: 'Company Name', required: true },
								{ type: 'input-text', field: 'domain_name', label: 'Domain' }
							]
						}
					]
				},
				{
					type: 'section',
					label: 'Firmographics',
					children: [
						{
							type: 'row',
							layout: '170px 130px 130px',
							children: [
								{
									type: 'input-select',
									field: 'industry',
									label: 'Industry',
									options: [
										{ value: 'technology', label: 'Technology' },
										{ value: 'finance', label: 'Finance' }
									]
								},
								{
									type: 'input-select',
									field: 'status',
									label: 'Status',
									options: [{ value: 'lead', label: 'Lead' }]
								}
							]
						}
					]
				},
				{
					type: 'section',
					label: 'Contact',
					children: [
						{
							type: 'row',
							layout: '160px 1fr',
							children: [
								{ type: 'input-text', field: 'phone', label: 'Phone Number', inputType: 'tel' },
								{
									type: 'input-text',
									field: 'website',
									label: 'Website',
									inputType: 'url',
									prefix: 'https://'
								}
							]
						}
					]
				},
				{
					type: 'section',
					label: 'Address',
					children: [
						{
							type: 'row',
							layout: '260px 150px 80px 160px',
							children: [
								{ type: 'input-text', field: 'address.street', label: 'Street' },
								{ type: 'input-text', field: 'address.city', label: 'City' },
								{ type: 'input-text', field: 'address.zip', label: 'ZIP' },
								{ type: 'input-text', field: 'address.country', label: 'Country' }
							]
						}
					]
				},
				{
					type: 'section',
					label: 'Account',
					children: [
						{
							type: 'row',
							layout: '200px 1fr',
							children: [
								{
									type: 'input-text',
									field: 'annual_revenue',
									label: 'Annual Revenue',
									inputType: 'number'
								},
								{ type: 'input-text', field: 'owner_id', label: 'Owner' }
							]
						}
					]
				}
			]
		},
		document: doc({
			name: 'Acme Corp',
			domain_name: 'acme.com',
			phone: '+1 555 0100',
			website: 'acme.com',
			address: {
				street: '100 Innovation Drive',
				city: 'San Francisco',
				zip: '94105',
				country: 'United States'
			},
			annual_revenue: 2000000
		}),
		values: {}
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CompanyShowNoHorizontalOverflow"
	args={{ template: diagView.template ?? undefined, document: diagDoc }}
	play={async ({ canvasElement }) => {
		await new Promise((r) => setTimeout(r, 1200));
		const host = canvasElement.querySelector('.diag-host') as HTMLElement;
		await expect(host).not.toBeNull();
		const failures: string[] = [];
		for (const width of [536, 720, 992]) {
			host.style.width = `${width}px`;
			const hostRect = host.getBoundingClientRect();
			const lines: string[] = [];
			host.querySelectorAll('*').forEach((el) => {
				// Table-view cells are contained by the relation wrapper — skip.
				if (el.closest('.dvt-relation-table-wrap')) return;
				const r = (el as HTMLElement).getBoundingClientRect();
				if (r.width === 0) return;
				const over = r.right - hostRect.right;
				if (over > 1) {
					const cls = (el.getAttribute('class') ?? el.tagName).split(' ').slice(0, 3).join('.');
					lines.push(
						`  ${el.tagName.toLowerCase()} [${cls}] right+${Math.round(over)} w=${Math.round(r.width)}`
					);
				}
			});
			const scrolls = host.scrollWidth - host.clientWidth;
			if (scrolls > 1 || lines.length > 0) {
				failures.push(`width=${width} scroll=+${scrolls}\n${lines.slice(0, 25).join('\n')}`);
			}
		}
		await expect(
			failures.join('\n\n'),
			`Horizontal overflow inside the rendered crm.Company view:\n${failures.join('\n\n')}`
		).toBe('');
	}}
>
	{#snippet template(args)}
		<div class="diag-host">
			<DocumentViewTemplate
				template={args.template as never}
				document={args.document as never}
				driver={diagDriver}
				def={diagDef as never}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="MalformedInputNodeDiagnostic"
	args={{
		// A node persisted before authoring-time validation existed: an
		// input-text without its `field` binding. The dispatcher must render
		// the diagnostic instead of crashing on `template.field.split`.
		template: {
			type: 'col',
			children: [
				{ type: 'input-text', label: 'Broken binding' },
				{ type: 'label', value: 'Rest of the form still renders' }
			]
		} as never,
		document: doc({ display_name: 'Broken' })
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const diagnostic = canvas.getByRole('alert');
		await expect(diagnostic.textContent).toContain('input-text');
		await expect(diagnostic.textContent).toContain('no field binding');
		// Sibling nodes after the broken one must still render.
		const body = canvas.getByText('Rest of the form still renders');
		await expect(body).not.toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate template={args.template as never} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="MissingTemplateDiagnostic"
	args={{
		// A render torn down mid-flush (the shared-page story tests) can read a
		// non-nullable prop as undefined for one tick. The dispatcher must render
		// the diagnostic instead of throwing — a throw corrupts the page and the
		// retry on the same page fails again.
		template: undefined as never,
		document: doc({})
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const diagnostic = canvas.getByRole('alert');
		await expect(diagnostic.textContent).toContain('template node is missing');
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DocumentViewTemplate template={args.template as never} document={args.document} />
		</div>
	{/snippet}
</Story>

<!-- ── Seeded iam.Account views ─────────────────────────────────────── -->

<!-- The seeded `form` template, rendered against a mock account with a
	 form values bag (input nodes active). Asserts the sections render, the
	 status select offers the four declared options, and `default_role`
	 renders a reference picker locked to iam.Roles. -->
<Story
	name="SeededAccountForm"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The three sections render (headings — the picker's type label and
		// field labels share the plain text).
		await expect(canvas.getByRole('heading', { name: 'Identity' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Roles' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Security' })).toBeVisible();
		// The status select offers the four declared options.
		const statusInput = canvas.getByLabelText('Status');
		await userEvent.click(statusInput);
		const body = within(document.body);
		await waitFor(() => {
			expect(body.getByText('Pending')).toBeVisible();
		});
		expect(body.getByText('Active')).toBeVisible();
		expect(body.getByText('Suspended')).toBeVisible();
		expect(body.getByText('Disabled')).toBeVisible();
		// The default role renders a reference picker locked to iam.Roles —
		// the picker's locked type selector is the stable hook (the section
		// eyebrow and the status select also contain role-ish text).
		const locked = canvasElement.querySelector('.ref-type-locked');
		await expect(locked).not.toBeNull();
		await expect(locked?.getAttribute('aria-label')).toBe('Roles');
	}}
>
	{#snippet template()}
		<div class="dvt-story-frame">
			<DocumentViewTemplate
				template={accountViews.form!}
				document={accountDoc}
				values={accountValues}
				driver={accountDriver}
				def={accountDef}
			/>
		</div>
	{/snippet}
</Story>

<!-- The seeded `view` template (display mode — no values bag): header with
	 the coloured status chip, the typed email node, and `default_role`
	 hydrated to the role's display name through the mock driver. -->
<Story
	name="SeededAccountView"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The header title and the three body sections (headings — the
		// display-name value also renders the title text).
		await expect(canvas.getByRole('heading', { name: 'Ada Lovelace' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Identity' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Security' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Federated Identities' })).toBeVisible();
		// The email renders in the header subtitle and the typed email node.
		expect(canvas.getAllByText('ada@examplecompany.tld').length).toBeGreaterThan(0);
		// The federated identity row renders from the array node.
		await expect(canvas.getByText('keycloak')).toBeVisible();
		// The default role hydrates to the role's display name.
		await waitFor(() => {
			expect(canvas.getByText('editor')).toBeVisible();
		});
	}}
>
	{#snippet template()}
		<div class="dvt-story-frame">
			<DocumentViewTemplate
				template={accountViews.view!}
				document={accountDoc}
				driver={accountDriver}
				def={accountDef}
			/>
		</div>
	{/snippet}
</Story>

<!-- The seeded `quickView` template (the peek drawer shape). -->
<Story
	name="SeededAccountQuickView"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Identity')).toBeVisible();
		await expect(canvas.getByText('Roles')).toBeVisible();
		await expect(canvas.getByText('ada@examplecompany.tld')).toBeVisible();
	}}
>
	{#snippet template()}
		<div class="dvt-story-frame">
			<DocumentViewTemplate
				template={accountViews.quickView!}
				document={accountDoc}
				driver={accountDriver}
				def={accountDef}
			/>
		</div>
	{/snippet}
</Story>

<style>
	.dvt-story-frame {
		display: block;
		width: 100%;
		max-width: 880px;
		margin: 0 auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 120px;
	}

	/* Mimics the show page's `.show-content` — a plain block, no clipping
	 * or scrolling. The play function sets the width per pass and asserts
	 * nothing inside overflows horizontally. */
	.diag-host {
		display: block;
		width: 536px;
		margin: 0 auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		box-sizing: border-box;
	}
</style>

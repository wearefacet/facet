<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DoctypeViewPreview from './DoctypeViewPreview.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { TemplateNode } from '$lib/template-types';
	import { VIEW_KINDS, type ViewKind } from '$lib/doctype/previewDocument.js';

	const driver = createMockDriver();

	/**
	 * `core.DocumentView` fixture for `hr.Employee` ships three kinds:
	 * `view`, `form`, `quickView`. Pulled from `data/fixtures/core.DocumentView/hr.Employee.yml`.
	 * `inline` and `card` are intentionally absent so the story demonstrates the
	 * fallback path (a default template generated from the doctype definition).
	 */
	const employeeView: TemplateNode = {
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
							{ type: 'col', children: [{ type: 'title', value: '$person', level: 1 }] },
							{
								type: 'col',
								children: [
									{ type: 'capsule', value: '$current_title' },
									{ type: 'capsule', value: '$status' },
									{ type: 'hr' },
									{ type: 'field', label: 'Current Title', value: '$current_title' },
									{ type: 'field', label: 'Tenure (days)', value: '$tenure_days' },
									{ type: 'field', label: 'Person', value: '$person' },
									{ type: 'field', label: 'Manager', value: '$manager' }
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
					{ type: 'field', label: 'Job Title', value: '$job_title' },
					{ type: 'field', label: 'Department', value: '$department' },
					{ type: 'field', label: 'Hire Date', value: '$hire_date' },
					{ type: 'field', label: 'Termination Date', value: '$termination_date' },
					{ type: 'field', label: 'Salary', value: '$salary' },
					{ type: 'field', label: 'Remote', value: '$remote' }
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
						children: [{ type: 'label', value: '✅ Active — in good standing' }],
						else: [{ type: 'label', value: '⛔ Not active' }]
					}
				]
			}
		]
	};

	const employeeQuickView: TemplateNode = {
		type: 'col',
		children: [
			{ type: 'title', value: '$current_title', level: 2 },
			{ type: 'capsule', value: '$status' },
			{ type: 'hr' },
			{ type: 'field', label: 'Department', value: '$department' },
			{ type: 'field', label: 'Hire Date', value: '$hire_date' },
			{ type: 'field', label: 'Manager', value: '$manager' },
			{ type: 'field', label: 'Remote', value: '$remote' },
			{ type: 'field', label: 'Person', value: '$person' },
			{ type: 'field', label: 'Salary', value: '$salary' }
		]
	};

	const employeeForm: TemplateNode = {
		type: 'col',
		children: [
			{
				type: 'input-select',
				field: 'status',
				label: 'Status',
				options: [
					{ value: 'active', label: 'Active' },
					{ value: 'on_leave', label: 'On leave' },
					{ value: 'terminated', label: 'Terminated' }
				]
			},
			{
				type: 'input-text',
				field: 'hire_date',
				label: 'Hire Date',
				inputType: 'date',
				required: true
			},
			{
				type: 'input-text',
				field: 'termination_date',
				label: 'Termination Date',
				inputType: 'date'
			},
			{ type: 'input-text', field: 'job_title', label: 'Job Title', required: true },
			{ type: 'input-text', field: 'department', label: 'Department' },
			{ type: 'input-text', field: 'salary', label: 'Salary', inputType: 'number' },
			{ type: 'input-toggle', field: 'remote', label: 'Remote' },
			{ type: 'input-reference', field: 'person', label: 'Person', required: true },
			{ type: 'input-reference', field: 'manager', label: 'Manager' }
		]
	};

	/** Resolve + parse a doctype definition by qualified name from the mock driver. */
	function defFor(qualifiedName: string): DoctypeDef {
		const raw = driver.doctypeDefinitions.get(qualifiedName);
		if (!raw) throw new Error(`mock doctype ${qualifiedName} not registered`);
		return parseDoctypeDef(raw) as DoctypeDef;
	}

	const employeeDef = defFor('hr.Employee');
	const dealDef = defFor('crm.Deal');
	const companyDef = defFor('crm.Company');
	const candidateDef = defFor('hr.Candidate');

	const employeeViews: Partial<Record<ViewKind, TemplateNode | null>> = {
		view: employeeView,
		quickView: employeeQuickView,
		form: employeeForm
		// `inline` and `card` are deliberately absent — stories exercise the fallback path.
	};

	const emptyViews: Partial<Record<ViewKind, TemplateNode | null>> = {};

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/DoctypeViewPreview',
		component: DoctypeViewPreview,
		tags: ['autodocs'],
		argTypes: {
			kind: { control: 'select', options: [...VIEW_KINDS] }
		},
		args: {
			def: employeeDef,
			views: employeeViews,
			kind: 'view',
			driver
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<!-- Employee: defined kinds (view/form/quickView) -->
<Story name="Employee — view" args={{ def: employeeDef, views: employeeViews, kind: 'view' }} />
<Story name="Employee — form" args={{ def: employeeDef, views: employeeViews, kind: 'form' }} />
<Story
	name="Employee — quickView"
	args={{ def: employeeDef, views: employeeViews, kind: 'quickView' }}
/>

<!-- Employee: absent kinds (inline/card) — exercises the fallback path -->
<Story
	name="Employee — inline (fallback)"
	args={{ def: employeeDef, views: employeeViews, kind: 'inline' }}
/>
<Story
	name="Employee — card (fallback)"
	args={{ def: employeeDef, views: employeeViews, kind: 'card' }}
/>

<!-- Deal: no views declared at all — every kind shows the default fallback -->
<Story name="Deal — view (fallback)" args={{ def: dealDef, views: emptyViews, kind: 'view' }} />
<Story
	name="Deal — quickView (fallback)"
	args={{ def: dealDef, views: emptyViews, kind: 'quickView' }}
/>

<!-- Company, Candidate — short doctypes to spot-check field type coverage -->
<Story
	name="Company — view (fallback)"
	args={{ def: companyDef, views: emptyViews, kind: 'view' }}
/>
<Story
	name="Candidate — view (fallback)"
	args={{ def: candidateDef, views: emptyViews, kind: 'view' }}
/>

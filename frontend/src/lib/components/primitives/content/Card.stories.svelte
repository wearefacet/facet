<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import Card from './Card.svelte';
	import DocumentViewTemplate from '../../features/document-view/DocumentViewTemplate.svelte';
	import type { DocumentMeta, DocumentResponse } from '$lib/datasource/types';
	import type { TemplateNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Content/Card',
		tags: ['autodocs']
	});

	const employeeData: Record<string, unknown> = {
		employee_id: 'EMP-0042',
		first_name: 'Jane',
		last_name: 'Doe',
		email: 'jane.doe@company.com',
		email_label: 'jane.doe@company.com',
		phone: '+1-555-0123',
		department: 'Engineering',
		title: 'Senior Software Engineer',
		avatar_url: 'https://api.dicebear.com/9.x/notionists/svg?seed=Jane',
		skills: [
			{ name: 'TypeScript', level: 'expert' },
			{ name: 'Crystal', level: 'advanced' },
			{ name: 'PostgreSQL', level: 'intermediate' }
		]
	};

	const invoiceData: Record<string, unknown> = {
		number: 'INV-2024-001',
		client: 'Acme Corp',
		amount: 12400.0,
		status: 'overdue',
		due_date: '2024-08-15',
		items: [
			{ desc: 'Consulting Q3', qty: 40, rate: 250 },
			{ desc: 'Hosting fees', qty: 3, rate: 800 }
		]
	};

	const taskData: Record<string, unknown> = {
		name: 'Review Q3 budget',
		assignee: 'Jane Doe',
		due: '2024-08-15',
		status: 'in progress',
		priority: 'high',
		description: 'Go through all department submissions and flag outliers before the board meeting.'
	};

	function doc(data: Record<string, unknown>, docType = 'Employee'): DocumentResponse {
		return {
			data,
			meta: {
				id: 'test.1',
				mid: 'test.1',
				domain: 'test',
				doc_type: docType,
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	const employeeDoc = doc(employeeData, 'Employee');

	const compactTemplate: TemplateNode = {
		type: 'grid',
		layout: '1 3',
		children: [
			{
				type: 'col',
				children: [{ type: 'image', src: '$avatar_url', variant: 'avatar', alt: 'Employee photo' }]
			},
			{
				type: 'col',
				children: [
					{ type: 'title', value: '$first_name $last_name', level: 3 },
					{ type: 'capsule', value: '$title' }
				]
			}
		]
	};

	const fullTemplate: TemplateNode = {
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
					{ type: 'title', value: '$first_name $last_name', level: 3 },
					{ type: 'capsule', value: '$title' },
					{ type: 'field', label: 'Email', value: '$email' },
					{ type: 'field', label: 'Phone', value: '$phone' },
					{ type: 'field', label: 'Department', value: '$department' }
				]
			}
		]
	};

	const taskTemplate: TemplateNode = {
		type: 'col',
		children: [
			{ type: 'title', value: '$name', level: 4 },
			{ type: 'label', value: 'Due $due · $assignee' },
			{ type: 'label', value: '$description' }
		]
	};

	const invoiceTemplate: TemplateNode = {
		type: 'col',
		children: [
			{ type: 'title', value: '$number', level: 4 },
			{ type: 'field', label: 'Client', value: '$client' },
			{ type: 'field', label: 'Amount', value: '$amount' },
			{ type: 'field', label: 'Due', value: '$due_date' }
		]
	};
</script>

<!-- ── Same card constrained to different widths ────────────────────────── -->

<Story name="Narrow — 260px (kanban)">
	<div style="width:260px">
		<Card doctype="contact">
			<DocumentViewTemplate template={compactTemplate} document={employeeDoc} />
		</Card>
	</div>
</Story>

<Story name="Narrow — 260px (full fields)">
	<div style="width:260px">
		<Card doctype="task">
			<DocumentViewTemplate template={fullTemplate} document={employeeDoc} />
		</Card>
	</div>
</Story>

<Story name="Medium — 380px (peek drawer)">
	<div style="width:380px">
		<Card doctype="invoice">
			<DocumentViewTemplate template={invoiceTemplate} document={doc(invoiceData, 'Invoice')} />
		</Card>
	</div>
</Story>

<Story name="Medium — 380px (task)">
	<div style="width:380px">
		<Card doctype="task">
			<DocumentViewTemplate template={taskTemplate} document={doc(taskData, 'Task')} />
		</Card>
	</div>
</Story>

<Story name="Full — 100% (workspace)">
	<Card doctype="contract">
		<DocumentViewTemplate template={fullTemplate} document={employeeDoc} />
	</Card>
</Story>

<Story name="Full — 100% (compact)">
	<Card doctype="document">
		<DocumentViewTemplate template={compactTemplate} document={employeeDoc} />
	</Card>
</Story>

<Story name="Draggable — 260px">
	<div style="width:260px">
		<Card doctype="task" draggable={true}>
			<DocumentViewTemplate template={compactTemplate} document={employeeDoc} />
		</Card>
	</div>
</Story>

<Story name="Draggable — 380px">
	<div style="width:380px">
		<Card doctype="contact" draggable={true}>
			<DocumentViewTemplate template={compactTemplate} document={employeeDoc} />
		</Card>
	</div>
</Story>

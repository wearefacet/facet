<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within } from 'storybook/test';
	import ViewPreviewCard from './ViewPreviewCard.svelte';
	import type { ViewPreview } from '$lib/assistant/tool-call-helpers.js';
	import type { TemplateNode } from '$lib/template-types.js';

	const customerTemplate: TemplateNode = {
		type: 'col',
		children: [
			{
				type: 'section',
				label: 'Identity',
				children: [
					{ type: 'field', label: 'Name', value: '$name' },
					{ type: 'field', label: 'Email', value: '$email' },
					{ type: 'field', label: 'Phone', value: '$phone' }
				]
			},
			{
				type: 'section',
				label: 'Commercial',
				children: [
					{ type: 'field', label: 'Annual revenue', value: '$revenue' },
					{ type: 'field', label: 'Status', value: '$status' }
				]
			}
		]
	};

	const documentPreview: ViewPreview = {
		status: 'ok',
		spec: {
			kind: 'document',
			title: 'Customer show view',
			template: customerTemplate,
			sample_data: {
				name: 'Aurora Print Studio',
				revenue: { value: '184000.00', currency: 'USD' }
			}
		}
	};

	const tablePreview: ViewPreview = {
		status: 'ok',
		spec: {
			kind: 'collection',
			surface: 'table',
			title: 'Shipments — table',
			config: {
				columns: [
					{ key: 'reference_no', label: 'Reference', width: '140px' },
					{ key: 'status' },
					{ key: 'total_amount', label: 'Total' },
					{ key: 'pickup_date', label: 'Pickup' }
				]
			},
			sample_data: { reference_no: 'SHP-2026-0042' }
		}
	};

	const calendarPreview: ViewPreview = {
		status: 'ok',
		spec: {
			kind: 'collection',
			surface: 'calendar',
			title: 'Pickups — calendar',
			config: {
				discriminator: 'pickup_date',
				title_template: '{{ reference_no }}',
				week_start: 'monday'
			}
		}
	};

	const runningPreview: ViewPreview = { status: 'running', spec: null };
	const errorPreview: ViewPreview = { status: 'error', spec: null };
	const invalidPreview: ViewPreview = { status: 'ok', spec: null };

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/ViewPreviewCard',
		component: ViewPreviewCard,
		tags: ['autodocs'],
		argTypes: {
			preview: {
				control: 'object',
				description: 'The preview part carried by the tool_call (spec + status).'
			}
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story name="DocumentPreview" args={{ preview: documentPreview }} />

<Story name="TablePreview" args={{ preview: tablePreview }} />

<Story name="CalendarPreview" args={{ preview: calendarPreview }} />

<Story name="Running" args={{ preview: runningPreview }} />

<Story name="Error" args={{ preview: errorPreview }} />

<Story name="InvalidPayload" args={{ preview: invalidPreview }} />

<!-- Expanded overlay: the preview body renders at full size. -->
<Story
	name="ExpandedOverlay"
	play={async ({ canvas: _canvas, canvasElement }) => {
		const root = canvasElement.querySelector('.preview-card');
		await expect(root).not.toBeNull();
		const expandBtn = root!.querySelector<HTMLButtonElement>('.expand-btn');
		await expect(expandBtn).not.toBeNull();
		await userEvent.click(expandBtn!);
		const overlay = document.querySelector('.preview-overlay');
		await expect(overlay).not.toBeNull();
		const body = overlay!.querySelector('.overlay-body');
		await expect(body!.children.length).toBeGreaterThan(0);
		await within(document.body).getByRole('button', { name: 'Close preview' });
	}}
	args={{ preview: tablePreview }}
/>

<!-- Lazy mount: the body is empty until the card becomes visible. -->
<Story
	name="LazyBody"
	play={async ({ canvasElement }) => {
		const root = canvasElement.querySelector('.preview-card')!;
		// The story canvas is visible, so the card must mount its body.
		await new Promise((r) => setTimeout(r, 50));
		const body = root.querySelector('.preview-body');
		await expect(body).not.toBeNull();
	}}
	args={{ preview: documentPreview }}
/>

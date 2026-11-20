<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import CodeEditor from './CodeEditor.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/CodeEditor',
		component: CodeEditor,
		tags: ['autodocs'],
		argTypes: {
			language: {
				control: 'select',
				options: ['lua', 'markdown', 'json', 'yaml', 'html', 'sql', 'plain']
			}
		},
		args: {
			oninput: fn()
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const luaSample = `-- Calculate invoice totals with discount
local function calculate_total(items, discount_rate)
    local subtotal = 0
    for _, item in ipairs(items) do
        subtotal = subtotal + item.qty * item.rate
    end
    local discount = subtotal * (discount_rate or 0)
    return subtotal - discount
end

local items = {
    { qty = 10, rate = 150 },
    { qty = 3,  rate = 800 },
    { qty = 1,  rate = 2500 }
}

local total = calculate_total(items, 0.05)
facet.set('total', total)
facet.set('line_items', items)`;

	const markdownSample = `# Shipping Policy

**Last updated:** 2025-03-15

## Processing Times

Orders are processed within **1–2 business days**.

## Shipping Rates

| Service | Cost | Est. Delivery |
|---|---|---|
| Standard | $5.99 | 5–8 days |
| Express | $14.99 | 2–3 days |
| Overnight | $29.99 | Next business day |

> Orders over $100 qualify for **free standard shipping**.

## International

For international orders, please allow 5–14 business days for delivery.
Customs fees are the responsibility of the buyer.`;

	const jsonSample = `{
  "doctype": "invoice",
  "number": "INV-2025-0042",
  "client": "Acme Corp",
  "items": [
    { "desc": "Consulting", "qty": 40, "rate": 250 },
    { "desc": "Hosting", "qty": 3, "rate": 800 }
  ],
  "total": 12400.0,
  "status": "pending"
}`;
</script>

<!-- ── Lua stories ───────────────────────────────────────────── -->

<Story
	name="Lua (empty)"
	args={{ language: 'lua', label: 'Pre-save script', placeholder: '-- Write your Lua script here' }}
/>

<Story
	name="Lua (with content)"
	args={{
		language: 'lua',
		label: 'Invoice script',
		value: luaSample,
		helper: 'This script runs before the document is saved.'
	}}
/>

<Story
	name="Lua (readonly)"
	args={{
		language: 'lua',
		label: 'System script',
		value: luaSample,
		readonly: true
	}}
/>

<Story
	name="Lua (disabled)"
	args={{
		language: 'lua',
		label: 'Archived script',
		value: luaSample,
		disabled: true
	}}
/>

<Story
	name="Lua (with error)"
	args={{
		language: 'lua',
		label: 'Migration script',
		value: luaSample,
		error: 'Syntax error at line 12: unexpected symbol near "facet"'
	}}
/>

<!-- ── Markdown stories ─────────────────────────────────────── -->

<Story
	name="Markdown (empty)"
	args={{
		language: 'markdown',
		label: 'Description',
		placeholder: 'Write your markdown description here…'
	}}
/>

<Story
	name="Markdown (with content)"
	args={{
		language: 'markdown',
		label: 'Shipping policy',
		value: markdownSample,
		helper: 'Used in the email template for order confirmations.'
	}}
/>

<Story
	name="Markdown (readonly)"
	args={{
		language: 'markdown',
		label: 'Release notes (v2.4.0)',
		value: markdownSample,
		readonly: true
	}}
/>

<Story
	name="Markdown (with error)"
	args={{
		language: 'markdown',
		label: 'Article body',
		value: markdownSample,
		error: 'Exceeds maximum length of 10,000 characters'
	}}
/>

<!-- ── Other languages ──────────────────────────────────────── -->

<Story
	name="JSON (with content)"
	args={{
		language: 'json',
		label: 'Configuration',
		value: jsonSample,
		helper: 'Document defaults for the invoice doctype.'
	}}
/>

<Story
	name="Minimal (no label)"
	args={{
		language: 'lua',
		value: 'return facet.get("total")'
	}}
/>

<Story
	name="Custom min-height"
	args={{
		language: 'markdown',
		label: 'Short note',
		value: 'A small piece of content.',
		minHeight: '100px'
	}}
/>

<Story
	name="Expanded (Lua)"
	args={{
		language: 'lua',
		label: 'Invoice script (expanded)',
		value: luaSample,
		expanded: true
	}}
/>

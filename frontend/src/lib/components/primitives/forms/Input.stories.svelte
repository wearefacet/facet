<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, fn } from 'storybook/test';
	import Input from './Input.svelte';
	import { Search, DollarSign, ShoppingBag } from '@lucide/svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/Input',
		component: Input,
		tags: ['autodocs'],
		argTypes: {
			type: {
				control: 'select',
				options: ['text', 'number', 'email', 'password']
			}
		},
		args: {
			oninput: fn(),
			onchange: fn()
		}
	});
</script>

{#snippet iconSearch()}
	<Search size={14} />
{/snippet}

{#snippet iconDollar()}
	<DollarSign size={14} />
{/snippet}

{#snippet iconBag()}
	<ShoppingBag size={14} />
{/snippet}

<Story
	name="Default"
	args={{ label: 'Name', placeholder: 'Enter full name' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByLabelText('Name')).toBeVisible();
		await expect(canvas.getByPlaceholderText('Enter full name')).toBeVisible();
	}}
/>
<Story name="WithValue" args={{ label: 'Email', value: 'alice@example.com', type: 'email' }} />
<Story
	name="WithHelper"
	args={{ label: 'Username', helper: 'Must be at least 3 characters', placeholder: 'jdoe' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Must be at least 3 characters')).toBeVisible();
	}}
/>
<Story
	name="WithError"
	args={{ label: 'Age', error: 'Must be a positive number', type: 'number' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Must be a positive number')).toBeVisible();
		await expect(canvas.getByLabelText('Age')).toHaveAttribute('aria-invalid', 'true');
	}}
/>
<Story
	name="Required"
	args={{ label: 'Phone', required: true, placeholder: '+1 (555) 000-0000' }}
/>
<Story
	name="Disabled"
	args={{ label: 'Locked', value: 'Cannot edit', disabled: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByLabelText('Locked')).toBeDisabled();
	}}
/>
<Story name="Password" args={{ label: 'Password', type: 'password', placeholder: '••••••••' }} />

<Story
	name="ScopedIdsAcrossRows"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Two rows render the same field label — the inline child-row shape.
		// The id scope keeps the DOM ids unique and every <label for>
		// association valid (B-394).
		const inputs = canvas.getAllByLabelText('Qty');
		expect(inputs).toHaveLength(2);
		const ids = inputs.map((el) => el.id);
		expect(ids).toEqual(['input-row-1-Qty', 'input-row-2-Qty']);
		expect(new Set(ids).size).toBe(ids.length);
		// Each id resolves to exactly one element — no duplicates anywhere.
		for (const id of ids) {
			expect(canvasElement.querySelectorAll(`[id="${id}"]`)).toHaveLength(1);
			// The visible label points at its own input.
			const label = canvasElement.querySelector(`label[for="${id}"]`);
			expect(label?.textContent?.trim()).toBe('Qty');
		}
	}}
>
	{#snippet template()}
		<div style="display: grid; gap: 12px;">
			<Input label="Qty" idScope="row-1" value="2" />
			<Input label="Qty" idScope="row-2" value="5" />
		</div>
	{/snippet}
</Story>

<Story
	name="IconLeft"
	args={{ label: 'Search', placeholder: 'Search invoices…', iconLeft: iconSearch }}
/>
<Story
	name="IconRight"
	args={{ label: 'Amount', placeholder: '0.00', type: 'number', iconRight: iconDollar }}
/>
<Story
	name="BothIcons"
	args={{ label: 'Price', value: '299.99', iconLeft: iconBag, iconRight: iconDollar }}
/>

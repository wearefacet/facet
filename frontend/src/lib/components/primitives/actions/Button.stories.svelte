<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn } from 'storybook/test';
	import Button from './Button.svelte';
	import { Search, ArrowRight, Menu, ChevronDown, Cog } from '@lucide/svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Actions/Button',
		component: Button,
		tags: ['autodocs'],
		argTypes: {
			variant: {
				control: 'select',
				options: ['primary', 'secondary', 'danger', 'ghost']
			},
			size: {
				control: 'select',
				options: ['sm', 'md', 'lg']
			}
		},
		args: {
			onclick: fn()
		}
	});
</script>

{#snippet iconSearch()}
	<Search size={14} />
{/snippet}

{#snippet iconArrowRight()}
	<ArrowRight size={14} />
{/snippet}

{#snippet iconMenu()}
	<Menu size={14} />
{/snippet}

{#snippet iconChevronDown()}
	<ChevronDown size={14} />
{/snippet}

{#snippet iconCog()}
	<Cog size={14} />
{/snippet}

<Story
	name="Primary"
	args={{ label: 'Save', variant: 'primary' }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('button', { name: 'Save' })).toBeVisible();
		await userEvent.click(canvas.getByRole('button', { name: 'Save' }));
		await expect(args.onclick).toHaveBeenCalledOnce();
	}}
/>
<Story name="Secondary" args={{ label: 'Cancel', variant: 'secondary' }} />
<Story name="Danger" args={{ label: 'Delete', variant: 'danger' }} />
<Story name="Ghost" args={{ label: 'More', variant: 'ghost' }} />

<Story name="Small" args={{ label: 'Tiny', size: 'sm' }} />
<Story name="Large" args={{ label: 'Big', size: 'lg' }} />

<Story
	name="Disabled"
	args={{ label: 'Disabled', disabled: true }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const btn = canvas.getByRole('button', { name: 'Disabled' });
		await expect(btn).toBeDisabled();
		await expect(args.onclick).not.toHaveBeenCalled();
	}}
/>

<Story
	name="Loading"
	args={{ label: 'Saving…', loading: true }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const btn = canvas.getByRole('button', { name: 'Saving…' });
		await expect(btn).toHaveAttribute('aria-busy', 'true');
		await expect(args.onclick).not.toHaveBeenCalled();
	}}
/>

<Story name="WithCaret" args={{ label: 'Actions', caret: true }} />

<Story
	name="WithMenu"
	args={{
		label: 'Actions',
		caret: true,
		menu: [
			{ label: 'Duplicate', onclick: fn() },
			{ label: 'Delete', onclick: fn() }
		]
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// One interactive element: the whole button is the trigger — a nested
		// DropdownMenu.Trigger here would emit <button><button>, which the
		// browser repairs during SSR and breaks hydration (B-61).
		const buttons = canvas.getAllByRole('button');
		await expect(buttons).toHaveLength(1);
		const trigger = buttons[0];
		await expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
		await userEvent.click(trigger);
		// The menu content is portalled to the document root, outside the canvas.
		const item = within(document.body).getByRole('menuitem', { name: 'Duplicate' });
		await expect(item).toBeVisible();
		await userEvent.click(item);
		await expect(args.menu?.[0]?.onclick).toHaveBeenCalledOnce();
	}}
/>

<Story
	name="Link"
	args={{ label: 'Navigate', href: '/somewhere' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const link = canvas.getByRole('button', { name: 'Navigate' });
		await expect(link.tagName).toBe('A');
		await expect(link).toHaveAttribute('href', '/somewhere');
	}}
/>

<Story name="IconLeft" args={{ label: 'Search', iconLeft: iconSearch }} />
<Story name="IconRight" args={{ label: 'Send', iconRight: iconArrowRight }} />
<Story
	name="BothIcons"
	args={{ label: 'Filter', iconLeft: iconMenu, iconRight: iconChevronDown }}
/>
<Story name="WithIconAndCaret" args={{ label: 'More', caret: true, children: iconCog }} />

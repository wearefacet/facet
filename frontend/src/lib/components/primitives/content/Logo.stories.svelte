<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import Logo from './Logo.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Content/Logo',
		component: Logo,
		tags: ['autodocs'],
		argTypes: {
			variant: {
				control: 'radio',
				options: ['mark', 'lockup']
			},
			size: {
				control: 'select',
				options: ['xs', 'sm', 'md', 'lg', 'xl']
			}
		}
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

	// Shared assertion for the theme-pinned card pairs: the light asset shows
	// only on the light card, the dark asset only on the dark one.
	const expectThemeSwitch = async (canvasElement: HTMLElement): Promise<void> => {
		await sleep(100);
		const card = (theme: string) => {
			const el = canvasElement.querySelector(`[data-theme='${theme}']`);
			expect(el, `${theme} card`).not.toBeNull();
			return el as HTMLElement;
		};
		// Match by variant class, not by src — the bundler inlines these small
		// SVGs as data URIs, so the file name is gone at runtime.
		const variantImg = (theme: string, variantClass: string) => {
			const img = within(card(theme))
				.getAllByAltText('Facet')
				.find((el) => el.classList.contains(variantClass));
			expect(img, `${variantClass} on the ${theme} card`).toBeDefined();
			return img as HTMLElement;
		};
		await expect(variantImg('light', 'logo-light')).toBeVisible();
		await expect(variantImg('light', 'logo-dark')).not.toBeVisible();
		await expect(variantImg('dark', 'logo-dark')).toBeVisible();
		await expect(variantImg('dark', 'logo-light')).not.toBeVisible();
	};
</script>

<!-- Size scale — the mark's width follows the preset; height tracks its
     78×58 aspect ratio. Each story renders against the default preview
     surface: charcoal mark in the light preview, white in the dark one. -->

<Story name="XS — 16px" args={{ size: 'xs' }} />
<Story name="SM — 24px" args={{ size: 'sm' }} />
<Story name="MD — 32px" args={{ size: 'md' }} />
<Story name="LG — 48px" args={{ size: 'lg' }} />
<Story name="XL — 96px" args={{ size: 'xl' }} />

<!-- Mark on the ground tint — the variant follows the preview theme -->

<Story name="On light ground">
	{#snippet template()}
		<div style="background:var(--ground);padding:32px;border-radius:9px;display:inline-flex">
			<Logo size="xl" />
		</div>
	{/snippet}
</Story>

<!-- Theme-driven variant. Each card pins its theme with a `data-theme`
     attribute — the same attribute the app sets on <html> — so the story
     renders identically in the light and the dark preview. The play function
     asserts the switch: charcoal on the light card, white on the dark one. -->

<Story
	name="On light and dark surfaces"
	play={({ canvasElement }) => expectThemeSwitch(canvasElement)}
>
	{#snippet template()}
		<div style="display:inline-flex;gap:16px">
			<div data-theme="light" style="background:#f4f6f8;padding:32px;border-radius:9px">
				<Logo size="lg" />
			</div>
			<div data-theme="dark" style="background:#0b0e13;padding:32px;border-radius:9px">
				<Logo size="lg" />
			</div>
		</div>
	{/snippet}
</Story>

<!-- Lockup — the same gem with the wordmark baked in. Height matches the
		 mark at the same preset, so both variants share the size grid. -->

<Story name="Lockup — sizes">
	{#snippet template()}
		<div style="display:inline-flex;align-items:flex-end;gap:24px">
			<Logo variant="lockup" size="sm" />
			<Logo variant="lockup" size="md" />
			<Logo variant="lockup" size="lg" />
			<Logo variant="lockup" size="xl" />
		</div>
	{/snippet}
</Story>

<Story
	name="Lockup — light and dark surfaces"
	play={({ canvasElement }) => expectThemeSwitch(canvasElement)}
>
	{#snippet template()}
		<div style="display:inline-flex;gap:16px">
			<div data-theme="light" style="background:#f4f6f8;padding:32px;border-radius:9px">
				<Logo variant="lockup" size="lg" />
			</div>
			<div data-theme="dark" style="background:#0b0e13;padding:32px;border-radius:9px">
				<Logo variant="lockup" size="lg" />
			</div>
		</div>
	{/snippet}
</Story>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import SetupForm from './SetupForm.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import type { AppContent } from '$lib/app/appTypes';

	/**
	 * Component tests for the setup step of the new-app wizard. The play
	 * functions use synthetic callbacks — no backend: the uniqueness check
	 * rides the `checkSlug` stub, the save rides `onContinue`, and the owner
	 * picker reads the mock driver. Each story mounts a fresh module in its
	 * own iframe, so the mocks never leak across stories.
	 */

	/** Fresh driver per iframe — the owner picker lists `core.DocType` from it. */
	const driver = createMockDriver();

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };
	const continueMock = (args: { onContinue: unknown }): AnyMock =>
		args.onContinue as unknown as AnyMock;
	const precheckMock = (args: { checkSlug: unknown }): AnyMock =>
		args.checkSlug as unknown as AnyMock;

	/** A loaded public draft, as the layout returns it on back-navigation. */
	function draft(overrides: Partial<AppContent> = {}): AppContent {
		return {
			slug: 'acme-portal',
			name: 'Acme Portal',
			client_type: 'public',
			allowed_origins: ['https://acme.example.com'],
			redirect_uris: ['https://acme.example.com/oauth/callback'],
			...overrides
		};
	}

	const { Story } = defineMeta({
		title: 'Components/Features/Apps/SetupForm',
		component: SetupForm,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): the embedded
		// ReferencePicker carries the violations logged on its own stories
		// (contrast / ARIA structure). Fix there, then remove this override.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="DerivedSlug"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Typing the name derives the slug live.
		await userEvent.type(canvas.getByLabelText('Display name'), 'Acme Portal');
		await expect(canvas.getByText('acme-portal')).toBeVisible();
	}}
	args={{
		app: null,
		issuerBase: 'https://facet.company.com',
		currentAccount: null,
		saving: false,
		checkSlug: fn(async (_slug: string) => false),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="ManualSlugPrecheckTaken"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText('Display name'), 'Taken App');
		// The derived slug feeds the debounced check (250 ms).
		await waitFor(() => {
			expect(precheckMock(args).mock.calls.length).toBeGreaterThan(0);
		});
		expect(precheckMock(args).mock.calls[0][0]).toBe('taken-app');
		// The manual slug input shows after "Edit"; its validation line
		// flags the taken slug.
		await userEvent.click(canvas.getByRole('button', { name: 'Edit' }));
		const slugInput = canvas.getByLabelText('Slug');
		await waitFor(() => {
			expect(slugInput).toHaveAttribute('aria-invalid', 'true');
		});
		await expect(canvas.getByText('This slug is already in use.')).toBeVisible();
	}}
	args={{
		app: null,
		issuerBase: '',
		currentAccount: null,
		saving: false,
		checkSlug: fn(async (_slug: string) => true),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="ContinueUpdatesDraftOmitsSlug"
	args={{
		app: { meta: { id: 'app.01TEST' }, data: draft() },
		issuerBase: 'https://facet.company.com',
		currentAccount: { id: 'iam.Account.ada', displayName: 'Ada Lovelace' },
		saving: false,
		checkSlug: fn(async (_slug: string) => false),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The draft seeds the fields. The slug is immutable after creation:
		// the input renders disabled, and the payload must not carry it —
		// the update hook rejects any patch that includes the key.
		const name = canvas.getByLabelText('Display name') as HTMLInputElement;
		await expect(name.value).toBe('Acme Portal');
		const slugInput = canvas.getByLabelText('Slug') as HTMLInputElement;
		await expect(slugInput.value).toBe('acme-portal');
		await expect(slugInput).toBeDisabled();
		const cont = canvas.getByRole('button', { name: 'Continue' });
		await expect(cont).toBeEnabled();
		await userEvent.click(cont);
		const payload = continueMock(args).mock.calls[0][0] as Partial<AppContent>;
		expect(payload.slug).toBeUndefined();
		expect(payload.name).toBe('Acme Portal');
		expect(payload.client_type).toBe('public');
		expect(payload.allowed_origins).toEqual(['https://acme.example.com']);
		expect(payload.redirect_uris).toEqual(['https://acme.example.com/oauth/callback']);
	}}
>
	{#snippet template(args)}
		<CanFixture manifest={{ '*.*': ['*'] }}>
			<SetupForm
				app={args.app}
				issuerBase={args.issuerBase}
				currentAccount={args.currentAccount}
				checkSlug={args.checkSlug}
				onContinue={args.onContinue}
				{driver}
			/>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="ContinueSubmitsFreshDraftSlug"
	args={{
		app: null,
		issuerBase: '',
		currentAccount: { id: 'iam.Account.ada', displayName: 'Ada Lovelace' },
		saving: false,
		checkSlug: fn(async (_slug: string) => false),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// A fresh setup derives the slug from the name; the create payload
		// is the only place the slug is ever sent.
		await userEvent.type(canvas.getByLabelText('Display name'), 'Acme Portal');
		await expect(canvas.getByText('acme-portal')).toBeVisible();
		const cont = canvas.getByRole('button', { name: 'Continue' });
		await expect(cont).toBeEnabled();
		await userEvent.click(cont);
		const payload = continueMock(args).mock.calls[0][0] as Partial<AppContent>;
		expect(payload.slug).toBe('acme-portal');
		expect(payload.name).toBe('Acme Portal');
	}}
>
	{#snippet template(args)}
		<CanFixture manifest={{ '*.*': ['*'] }}>
			<!-- app is hardcoded, not read from args: the addon's story-source
			     emitter crashes on a null arg referenced in a template
			     (valueToString reads a snippet symbol off null), and a fresh
			     setup is exactly the app-null case. -->
			<SetupForm
				app={null}
				issuerBase={args.issuerBase}
				currentAccount={args.currentAccount}
				checkSlug={args.checkSlug}
				onContinue={args.onContinue}
				{driver}
			/>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="ConfidentialShowsWebFields"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByLabelText('Display name')).toBeVisible();
		// Both client types edit the web fields here: a confidential app also
		// signs in through a browser, so it carries origins and redirect URIs.
		await expect(canvas.getByText('Allowed origins')).toBeVisible();
		await expect(canvas.getByText('Redirect URIs')).toBeVisible();
	}}
	args={{
		app: { meta: { id: 'app.01TEST' }, data: draft({ client_type: 'confidential' }) },
		issuerBase: 'https://facet.company.com',
		currentAccount: null,
		saving: false,
		checkSlug: fn(async (_slug: string) => false),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="SavingDisablesContinue"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// While the page writes the draft, the footer shows the saving
		// state and refuses a second submit.
		await expect(canvas.getByRole('button', { name: 'Saving…' })).toBeDisabled();
	}}
	args={{
		app: { meta: { id: 'app.01TEST' }, data: draft() },
		issuerBase: '',
		currentAccount: null,
		saving: true,
		checkSlug: fn(async (_slug: string) => false),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

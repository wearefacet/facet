<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import ReviewPanel from './ReviewPanel.svelte';
	import type { AppContent, DoctypeCatalogueEntry } from '$lib/app/appTypes';

	/**
	 * Component tests for the review step of the new-app wizard. The play
	 * functions use synthetic callbacks — no backend: `onFinish` and
	 * `onBack` record the calls, and the checklist renders from the fixture
	 * app. The catalogue fixture carries one sensitive doctype, so the
	 * consent footnote branch and the sensitive note on the grants row
	 * render.
	 */

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };
	const finishMock = (args: { onFinish: unknown }): AnyMock => args.onFinish as unknown as AnyMock;
	const backMock = (args: { onBack: unknown }): AnyMock => args.onBack as unknown as AnyMock;

	/** Two doctypes: one plain, one sensitive. */
	const catalogue: DoctypeCatalogueEntry[] = [
		{
			target: 'crm.Company',
			label: 'Company',
			description: 'Companies',
			domain: 'crm',
			pluralLabel: 'companies'
		},
		{
			target: 'crm.Contact',
			label: 'Contact',
			description: 'People',
			domain: 'crm',
			pluralLabel: 'contacts',
			sensitive: true
		}
	];

	/** A draft with every blocking item done, so only Publish sits open. */
	function readyApp(overrides: Partial<AppContent> = {}): AppContent {
		return {
			slug: 'acme-portal',
			name: 'Acme Portal',
			description: 'Portal for Acme partners',
			client_type: 'public',
			allowed_origins: ['https://acme.example.com'],
			redirect_uris: ['https://acme.example.com/oauth/callback'],
			grants: [
				{ target: 'crm.Company', actions: [{ name: 'read', required: true }] },
				{ target: 'crm.Contact', actions: [{ name: 'write', required: true }] }
			],
			...overrides
		};
	}

	const { Story } = defineMeta({
		title: 'Components/Features/Apps/ReviewPanel',
		component: ReviewPanel,
		tags: ['autodocs']
	});
</script>

<Story
	name="ReadyToPublish"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Review Acme Portal')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Publish' })).toBeEnabled();
		// The consent preview lists the granted doctypes by plural noun.
		await expect(canvas.getByText('wants to')).toBeVisible();
		await expect(canvas.getByText('companies')).toBeVisible();
		await expect(canvas.getByText('contacts')).toBeVisible();
		// Each done row links back to the step that sets it: identity,
		// origins, and URIs go to setup; grants go to permissions.
		const editLinks = canvas.getAllByRole('link', { name: 'Edit' });
		expect(editLinks.length).toBe(4);
		expect(editLinks[0].getAttribute('href')).toContain('/Configure/apps/new/setup');
		expect(editLinks[0].getAttribute('href')).toContain('app=app.01TEST');
	}}
	args={{
		app: readyApp(),
		appId: 'app.01TEST',
		catalogue,
		onBack: fn(async () => {}),
		onFinish: fn(async (_status: 'draft' | 'active') => {})
	}}
/>

<Story
	name="BlockedPublish"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No grants: the permissions row blocks, the Publish affordance
		// shows the open item instead of firing.
		await expect(canvas.getByRole('button', { name: 'Publish' })).toBeDisabled();
		await expect(canvas.getByText('Complete: Permissions')).toBeVisible();
		await expect(canvas.getByText('0 grant(s)')).toBeVisible();
		await expect(canvas.getByText('This app has not requested any permissions yet.')).toBeVisible();
	}}
	args={{
		app: readyApp({ grants: [] }),
		appId: 'app.01TEST',
		catalogue,
		onBack: fn(async () => {}),
		onFinish: fn(async (_status: 'draft' | 'active') => {})
	}}
/>

<Story
	name="ConfidentialServiceRole"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A backend app shows the service-role row beside the origin and
		// redirect rows — both types sign in through a browser.
		await expect(canvas.getByText('Service role')).toBeVisible();
		await expect(canvas.getByText('Allowed origins')).toBeVisible();
		await expect(canvas.getByText('Redirect URIs')).toBeVisible();
	}}
	args={{
		app: readyApp({
			client_type: 'confidential',
			service_role_id: 'iam.Roles.hr_service'
		}),
		appId: 'app.01TEST',
		catalogue,
		onBack: fn(async () => {}),
		onFinish: fn(async (_status: 'draft' | 'active') => {})
	}}
/>

<Story
	name="FinishActions"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Publish emits the active status; "Keep as draft" emits the draft
		// status. The page writes the status and owns the navigation.
		await userEvent.click(canvas.getByRole('button', { name: 'Publish' }));
		expect(finishMock(args).mock.calls[0][0]).toBe('active');
		await userEvent.click(canvas.getByRole('button', { name: 'Keep as draft' }));
		expect(finishMock(args).mock.calls[1][0]).toBe('draft');
	}}
	args={{
		app: readyApp(),
		appId: 'app.01TEST',
		catalogue,
		onBack: fn(async () => {}),
		onFinish: fn(async (_status: 'draft' | 'active') => {})
	}}
/>

<Story
	name="BusyWhilePublishing"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// While the page writes the status change, both footer buttons sit
		// disabled and the publish label shows the progress state.
		await expect(canvas.getByRole('button', { name: 'Publishing…' })).toBeDisabled();
		await expect(canvas.getByRole('button', { name: 'Keep as draft' })).toBeDisabled();
	}}
	args={{
		app: readyApp(),
		appId: 'app.01TEST',
		catalogue,
		busy: 'publish',
		onBack: fn(async () => {}),
		onFinish: fn(async (_status: 'draft' | 'active') => {})
	}}
/>

<Story
	name="BackAction"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Back' }));
		expect(backMock(args).mock.calls.length).toBe(1);
	}}
	args={{
		app: readyApp(),
		appId: 'app.01TEST',
		catalogue,
		onBack: fn(async () => {}),
		onFinish: fn(async (_status: 'draft' | 'active') => {})
	}}
/>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fireEvent, fn, userEvent, waitFor, within } from 'storybook/test';
	import PermissionsForm from './PermissionsForm.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import * as m from '$lib/paraglide/messages';
	import type { AppContent, AppGrant, DoctypeCatalogueEntry } from '$lib/app/appTypes';

	/**
	 * Component tests for the permissions step of the new-app wizard. The
	 * play functions use synthetic callbacks — no backend: `onContinue` and
	 * `onBack` record the calls, and the grants editor renders from the
	 * fixture catalogue. The service-role picker (confidential apps only)
	 * reads the mock driver; the grants-gap warning reads the seeded role
	 * permissions through it (admin covers every action, viewer reads only).
	 */

	/** Fresh driver per iframe — the service-role picker reads it. */
	const driver = createMockDriver();

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };
	const continueMock = (args: { onContinue: unknown }): AnyMock =>
		args.onContinue as unknown as AnyMock;
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

	/** A public draft with one grant, as the layout returns it. */
	function publicApp(overrides: Partial<AppContent> = {}): {
		meta: { id: string };
		data: AppContent;
	} {
		return {
			meta: { id: 'app.01TEST' },
			data: {
				slug: 'acme-portal',
				name: 'Acme Portal',
				client_type: 'public',
				grants: [{ target: 'crm.Company', actions: [{ name: 'read', required: true }] }],
				...overrides
			}
		};
	}

	/** A backend (confidential) draft — the service-role picker applies. */
	function confidentialApp(overrides: Partial<AppContent> = {}) {
		return publicApp({ client_type: 'confidential', ...overrides });
	}

	const { Story } = defineMeta({
		title: 'Components/Features/Apps/PermissionsForm',
		component: PermissionsForm,
		tags: ['autodocs'],
		// A11y backlog: the embedded ReferencePicker carries the violations
		// logged on its own stories (contrast / ARIA structure). Fix there,
		// then remove this override.
		parameters: { a11y: { test: 'todo' } }
	});

	/** A confidential draft whose grant demands write on crm.Company. */
	function writeApp(): {
		meta: { id: string };
		data: AppContent;
	} {
		return confidentialApp({
			grants: [{ target: 'crm.Company', actions: [{ name: 'write', required: true }] }]
		});
	}

	/** Open the role dropdown and pick a seeded role by name. */
	async function pickRole(canvas: ReturnType<typeof within>, name: string): Promise<void> {
		const input = await canvas.findByPlaceholderText('Search for a role…');
		await fireEvent.focus(input);
		await waitFor(() => {
			expect(canvas.getByText(name)).toBeVisible();
		});
		await userEvent.click(canvas.getByText(name));
	}

	/** The mock driver resolves in memory; one macrotask settles the load. */
	const settleLoad = () => new Promise((resolve) => setTimeout(resolve, 100));
</script>

<Story
	name="PublicAppGrantsOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A public app shows the wizard grants editor and no role picker.
		await expect(canvas.getByText('What can this app do?')).toBeVisible();
		await expect(canvas.queryByText('Service role')).toBeNull();
		// The seeded grant renders in the summary.
		await expect(canvas.getByText('companies')).toBeVisible();
		// No gap warning without the picker.
		await expect(canvas.queryByText(/401/)).toBeNull();
		// Continue is enabled — no service role blocks a public app.
		await expect(canvas.getByRole('button', { name: 'Continue' })).toBeEnabled();
	}}
	args={{
		app: publicApp(),
		catalogue,
		saving: false,
		onBack: fn(async () => {}),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="ConfidentialRequiresServiceRole"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A backend app picks its service role before Continue unlocks.
		await expect(canvas.getByText('Service role')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Continue' })).toBeDisabled();
		await expect(canvas.getByText('Pick a service role to continue.')).toBeVisible();
		// No role picked yet — no gap warning may fire.
		await expect(canvas.queryByText(/401/)).toBeNull();
	}}
	args={{
		app: confidentialApp(),
		catalogue,
		saving: false,
		onBack: fn(async () => {}),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="ServiceRoleGrantsGapWarning"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Pick a role that reads everything but cannot write: the grant
		// demands write, so the warning names both expanded halves.
		await pickRole(canvas, 'viewer');
		await waitFor(() => {
			expect(
				canvas.getByText(
					m.apps_role_not_usable_body({
						missing: 'create on crm.Company, update on crm.Company'
					})
				)
			).toBeVisible();
		});
		// Non-blocking: a picked role still unlocks Continue.
		await expect(canvas.getByRole('button', { name: 'Continue' })).toBeEnabled();
	}}
	args={{
		app: writeApp(),
		catalogue,
		saving: false,
		onBack: fn(async () => {}),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="ServiceRoleCoversGrants"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The admin role holds * on *.* — it satisfies the required write, so
		// no warning may appear once the role document has loaded.
		await pickRole(canvas, 'admin');
		await settleLoad();
		await expect(canvas.queryByText(/401/)).toBeNull();
		await expect(canvas.getByRole('button', { name: 'Continue' })).toBeEnabled();
	}}
	args={{
		app: writeApp(),
		catalogue,
		saving: false,
		onBack: fn(async () => {}),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="ServiceRoleWithoutApiChannelWarning"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The seeded `anonymous` role carries an empty connectivity list — no
		// `api` channel. The warning marks the role as unable to carry a
		// service key (issuance refuses with 422).
		await pickRole(canvas, 'anonymous');
		await waitFor(() => {
			expect(canvas.getByText(m.configure_apps_role_no_api_channel())).toBeVisible();
		});
		// Non-blocking: the operator may still save the draft and fix the role.
		await expect(canvas.getByRole('button', { name: 'Continue' })).toBeEnabled();
	}}
	args={{
		app: confidentialApp(),
		catalogue,
		saving: false,
		onBack: fn(async () => {}),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="ServiceRoleSubmitsProjectionId"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Open the role dropdown. The mock driver serves the seeded iam.Roles
		// rows; their projection ids are self-qualified (`iam.Roles.editor`).
		const input = await canvas.findByPlaceholderText('Search for a role…');
		await fireEvent.focus(input);
		await waitFor(() => {
			expect(canvas.getByText('editor')).toBeVisible();
		});
		await userEvent.click(canvas.getByText('editor'));
		// A picked role unlocks Continue.
		const continueButton = canvas.getByRole('button', { name: 'Continue' });
		await waitFor(() => expect(continueButton).toBeEnabled());
		await userEvent.click(continueButton);
		await expect(continueMock(args).mock.calls.length).toBe(1);
		const payload = continueMock(args).mock.calls[0][0] as {
			grants: AppGrant[];
			service_role_id?: string;
		};
		// The payload carries the row's projection id — the form the backend
		// resolves for key issuance. A doubled `iam.Roles.iam.Roles.editor`
		// token is the defect this story guards against.
		await expect(payload.service_role_id).toBe('iam.Roles.editor');
	}}
	args={{
		app: confidentialApp(),
		catalogue,
		saving: false,
		onBack: fn(async () => {}),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="ContinueReportsPayload"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Continue hands the seeded grants to the page — the payload the
		// page PATCHes onto the draft.
		await userEvent.click(canvas.getByRole('button', { name: 'Continue' }));
		await expect(continueMock(args).mock.calls.length).toBe(1);
		const payload = continueMock(args).mock.calls[0][0] as {
			grants: AppGrant[];
			service_role_id?: string;
		};
		await expect(payload.grants).toEqual([
			{ target: 'crm.Company', actions: [{ name: 'read', required: true }] }
		]);
		// A public app sends no service_role_id.
		await expect(payload.service_role_id).toBeUndefined();
	}}
	args={{
		app: publicApp(),
		catalogue,
		saving: false,
		onBack: fn(async () => {}),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

<Story
	name="BackReportsToHost"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Back' }));
		await expect(backMock(args).mock.calls.length).toBe(1);
	}}
	args={{
		app: publicApp(),
		catalogue,
		saving: false,
		onBack: fn(async () => {}),
		onContinue: fn(async (_payload: Partial<AppContent>) => {}),
		driver
	}}
/>

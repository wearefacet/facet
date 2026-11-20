<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor, fn } from 'storybook/test';
	import AppSettingsForm from './AppSettingsForm.svelte';
	import type { AppContent } from '$lib/app/appTypes';
	import { setPermissions } from '$lib/permissions.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Component tests for the Settings tab form. The form owns the draft;
	 * `onSave` and `onDelete` are spies, so no backend runs. The plays pin
	 * the flat-patch contract: one Save sends exactly its section's fields.
	 * The admin wildcard hydrates the global permission store before the
	 * first story mounts, so the Can-gated Save and Delete buttons render.
	 * Fixtures rebuild per story — the sync effect would otherwise read
	 * edits leaked from an earlier story. The service-role stories read the
	 * mock driver (the seeded roles carry the connectivity the warning
	 * checks).
	 */

	setPermissions({ '*.*': ['*'] });

	/** Fresh driver per iframe — the service-role picker reads it. */
	const mockDriver = createMockDriver();

	/** A public (PKCE) web app with one redirect and one origin. */
	function publicApp(): AppContent {
		return {
			slug: 'time-off',
			name: 'Time Off',
			client_id: '01J8Z0M8Z3Q7V4XK9P2RNW5T6H',
			client_type: 'public',
			status: 'active',
			allowed_origins: ['https://time.example.com'],
			redirect_uris: ['https://time.example.com/oauth/callback'],
			compatible_roles: ['iam.Roles.time-off-user']
		};
	}

	/** A backend app — the API key section applies. */
	function confidentialApp(): AppContent {
		return { ...publicApp(), client_type: 'confidential' };
	}

	/** A backend app whose service role is set — seeded roles carry `api`. */
	function confidentialAppWithRole(): AppContent {
		return { ...confidentialApp(), service_role_id: 'iam.Roles.admin' };
	}

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };
	const cbMock = (args: Record<string, unknown>, key: string): AnyMock =>
		args[key] as unknown as AnyMock;

	const baseArgs = () => ({
		appId: 'app-1',
		busy: false,
		onSave: fn(async (_patch: Record<string, unknown>) => {}),
		onDelete: fn(() => {})
	});

	/** The section that carries the given heading text. */
	function section(canvas: ReturnType<typeof within>, heading: string): HTMLElement {
		const el = canvas.getByRole('heading', { name: heading }).closest('section');
		if (!el) throw new Error(`No section for heading "${heading}"`);
		return el;
	}

	const { Story } = defineMeta({
		title: 'Components/Features/Apps/AppSettingsForm',
		component: AppSettingsForm,
		tags: ['autodocs']
	});
</script>

<Story
	name="Default"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Read-only identity fields render from the document.
		await expect(canvas.getByLabelText('Slug')).toHaveValue('time-off');
		await expect(canvas.getByLabelText('Client ID')).toHaveValue('01J8Z0M8Z3Q7V4XK9P2RNW5T6H');
		// Every editable section renders.
		await expect(canvas.getByRole('heading', { name: 'Client type' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Origins and redirects' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Compatible roles' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Headless flags' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Serving' })).toBeVisible();
		await expect(canvas.getByRole('heading', { name: 'Assistant' })).toBeVisible();
		// Existing draft values render as chips.
		await expect(canvas.getByText('https://time.example.com/oauth/callback')).toBeVisible();
		await expect(canvas.getByText('https://time.example.com')).toBeVisible();
		await expect(canvas.getByText('iam.Roles.time-off-user')).toBeVisible();
		// A public app carries no API key section and no service identity.
		await expect(canvas.queryByRole('heading', { name: 'API key' })).toBeNull();
		await expect(canvas.queryByRole('heading', { name: 'Service identity' })).toBeNull();
		// The danger zone closes the tab.
		await expect(canvas.getByRole('button', { name: 'Delete app' })).toBeVisible();
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="ConfidentialShowsApiKeySection"
	parameters={{
		// A11y backlog: the embedded ReferencePicker carries the violations
		// logged on its own stories (contrast / ARIA structure). Fix there,
		// then remove this override.
		a11y: { test: 'todo' }
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A confidential app manages its key on this tab.
		await expect(canvas.getByRole('heading', { name: 'API key' })).toBeVisible();
		// The service identity section renders beside it.
		await expect(canvas.getByRole('heading', { name: 'Service identity' })).toBeVisible();
		// No role on the document: the role Save is disabled, Generate is
		// disabled, and the muted line names the missing piece.
		await expect(
			within(section(canvas, 'Service identity')).getByRole('button', { name: 'Save' })
		).toBeDisabled();
		await expect(
			canvas.getByRole('button', { name: m.configure_apps_generate_key() })
		).toBeDisabled();
		await expect(canvas.getByText(m.configure_apps_key_needs_role())).toBeVisible();
		// The assistant section renders for both client types — a
		// `confidential` app signs in through a browser too.
		await expect(canvas.getByRole('heading', { name: 'Assistant' })).toBeVisible();
	}}
	args={{ app: confidentialApp(), ...baseArgs() }}
/>

<Story
	name="SaveServiceRoleSendsPatch"
	parameters={{ a11y: { test: 'todo' } }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const roleSection = section(canvas, 'Service identity');
		// The role seeds from the document; Save reports it unchanged.
		await userEvent.click(within(roleSection).getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(cbMock(args, 'onSave').mock.calls.length).toBe(1));
		const patch = cbMock(args, 'onSave').mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ service_role_id: 'iam.Roles.admin' });
		// admin carries the `api` channel: no issuance warning.
		await waitFor(() => {
			expect(within(roleSection).queryByRole('status')).toBeNull();
		});
	}}
	args={{ app: confidentialAppWithRole(), driver: mockDriver, ...baseArgs() }}
/>

<Story
	name="ServiceRoleWithoutApiChannelWarns"
	parameters={{ a11y: { test: 'todo' } }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The seeded anonymous role carries no connectivity at all: the
		// warning names the gap without blocking the Save.
		await waitFor(() => {
			expect(canvas.getByText(m.configure_apps_role_no_api_channel())).toBeVisible();
		});
		await expect(
			within(section(canvas, 'Service identity')).getByRole('button', { name: 'Save' })
		).toBeEnabled();
	}}
	args={{
		app: { ...confidentialApp(), service_role_id: 'iam.Roles.anonymous' },
		driver: mockDriver,
		...baseArgs()
	}}
/>

<Story
	name="SaveAssistantSendsPatch"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const assistant = section(canvas, 'Assistant');
		// The defaults read off the document: the flag off, no prompt.
		await expect(
			within(assistant).getByRole('switch', { name: 'Enable the assistant' })
		).toHaveAttribute('aria-checked', 'false');
		// Flip the toggle and type the app's own instructions.
		await userEvent.click(within(assistant).getByRole('switch', { name: 'Enable the assistant' }));
		const prompt = within(assistant).getByRole('textbox', { name: 'App instructions' });
		await userEvent.type(prompt, 'Answer about the CRM only.');
		// One Save sends exactly the section's two fields.
		await userEvent.click(within(assistant).getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(cbMock(args, 'onSave').mock.calls.length).toBe(1));
		const patch = cbMock(args, 'onSave').mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({
			assistant_enabled: true,
			assistant_prompt: 'Answer about the CRM only.'
		});
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="SaveClientTypeSendsPatch"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The section's Save reports the section's field, unchanged value.
		await userEvent.click(
			within(section(canvas, 'Client type')).getByRole('button', { name: 'Save' })
		);
		await waitFor(() => expect(cbMock(args, 'onSave').mock.calls.length).toBe(1));
		const patch = cbMock(args, 'onSave').mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ client_type: 'public' });
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="SaveRedirectUrisSendsPatch"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Add one URI to the editor, then save that field row. The section
		// carries two Save buttons (redirects and origins), so scope to the
		// row that owns the Redirect URIs editor.
		const input = within(section(canvas, 'Origins and redirects')).getByRole('textbox', {
			name: 'Redirect URIs'
		});
		await userEvent.type(input, 'https://new.example.com/callback{Enter}');
		const row = input.closest('.field-row');
		if (!row) throw new Error('No field-row wraps the Redirect URIs editor');
		await userEvent.click(within(row as HTMLElement).getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(cbMock(args, 'onSave').mock.calls.length).toBe(1));
		const patch = cbMock(args, 'onSave').mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({
			redirect_uris: ['https://time.example.com/oauth/callback', 'https://new.example.com/callback']
		});
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="SaveHeadlessFlagsSendsPatch"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Flip one flag; the save carries both flags of the section.
		await userEvent.click(
			within(section(canvas, 'Headless flags')).getByRole('switch', {
				name: 'Hide from the launcher'
			})
		);
		await userEvent.click(
			within(section(canvas, 'Headless flags')).getByRole('button', { name: 'Save' })
		);
		await waitFor(() => expect(cbMock(args, 'onSave').mock.calls.length).toBe(1));
		const patch = cbMock(args, 'onSave').mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ no_launcher: true, no_asset: false });
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="SaveHostSendsPatch"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Type a hostname and save: one flat patch carries the host.
		await userEvent.type(canvas.getByLabelText('Host'), 'hr.example.com');
		await userEvent.click(within(section(canvas, 'Serving')).getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(cbMock(args, 'onSave').mock.calls.length).toBe(1));
		const patch = cbMock(args, 'onSave').mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ host: 'hr.example.com' });
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="SaveHostClearsFieldWithNull"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The fixture carries a host; clearing the input and saving PATCHes
		// RFC 7386 style — `null` removes the key from the merged document.
		const input = canvas.getByLabelText('Host');
		await expect(input).toHaveValue('hr.example.com');
		await userEvent.clear(input);
		await userEvent.click(within(section(canvas, 'Serving')).getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(cbMock(args, 'onSave').mock.calls.length).toBe(1));
		const patch = cbMock(args, 'onSave').mock.calls[0][0] as Record<string, unknown>;
		await expect(patch).toEqual({ host: null });
	}}
	args={{ app: { ...publicApp(), host: 'hr.example.com' }, ...baseArgs() }}
/>

<Story
	name="SaveHostRejectsBadShapeLocally"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// A scheme-bearing value fails the client-side shape check (the
		// mirror of the backend hook rule); nothing reaches onSave.
		await userEvent.type(canvas.getByLabelText('Host'), 'https://hr.example.com');
		await userEvent.click(within(section(canvas, 'Serving')).getByRole('button', { name: 'Save' }));
		await expect(canvas.getByText(/bare lowercase hostname/i)).toBeVisible();
		await expect(cbMock(args, 'onSave').mock.calls.length).toBe(0);
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

<Story
	name="HostDisabledForNoAssetApp"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The Lua hook refuses a host on a no-asset app, so the editor sits
		// disabled and its helper names the reason.
		await expect(canvas.getByLabelText('Host')).toBeDisabled();
		await expect(canvas.getByText(m.configure_apps_host_helper_no_asset())).toBeVisible();
	}}
	args={{ app: { ...publicApp(), no_asset: true }, ...baseArgs() }}
/>

<Story
	name="DeleteReportsToHost"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The host confirms before it deletes; the form only reports.
		await userEvent.click(canvas.getByRole('button', { name: 'Delete app' }));
		await waitFor(() => expect(cbMock(args, 'onDelete').mock.calls.length).toBe(1));
	}}
	args={{ app: publicApp(), ...baseArgs() }}
/>

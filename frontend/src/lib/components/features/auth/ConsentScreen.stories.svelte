<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
	import ConsentScreen from './ConsentScreen.svelte';
	import {
		consentAcmePortal,
		consentMultipleRoles,
		consentRichScope,
		consentNoRoles,
		errorInvalidClient,
		errorInvalidRedirect,
		errorUnauthorizedClient,
		errorInvalidRequest,
		errorAccessDenied,
		multipleRolesDefaultPick,
		brandedProduct,
		mcpConsentSingle,
		mcpConsentMultiple,
		mcpConsentAdmin,
		mcpConsentNoRoles
	} from './mockConsentData';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/ConsentScreen',
		component: ConsentScreen,
		tags: ['autodocs'],
		args: {
			onconsent: fn(),
			oncancel: fn(),
			onretry: fn()
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story name="Default">
	{#snippet template()}
		<ConsentScreen consent={consentAcmePortal} />
	{/snippet}
</Story>

<Story name="MultipleRoles" args={{ preselectedRoleId: multipleRolesDefaultPick }}>
	{#snippet template(args)}
		<ConsentScreen
			consent={consentMultipleRoles}
			preselectedRoleId={args.preselectedRoleId}
			onconsent={args.onconsent}
			oncancel={args.oncancel}
		/>
	{/snippet}
</Story>

<Story name="RichScope">
	{#snippet template()}
		<ConsentScreen
			consent={consentRichScope}
			redirectUri="https://console.facet.internal/oauth/callback"
		/>
	{/snippet}
</Story>

<Story
	name="WildcardPlusSpecificScope"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A wildcard ceiling plus a specific grant on the same doctype
		// resolves to one merged row per doctype — the render must not
		// crash on duplicate keys, and both action sets show.
		await expect(canvas.getByText('crm.Contact')).toBeVisible();
		const invoiceCaps = canvas.getAllByText('crm.Invoice');
		await expect(invoiceCaps.length).toBe(1);
		const read = canvas.getAllByText('read').length;
		await expect(read).toBeGreaterThan(0);
		await expect(canvas.getAllByText('update').length).toBeGreaterThan(0);
	}}
>
	{#snippet template()}
		<ConsentScreen consent={consentRichScope} />
	{/snippet}
</Story>

<Story name="LoadingConsent">
	{#snippet template()}
		<ConsentScreen consent={null} loading={true} />
	{/snippet}
</Story>

<Story
	name="Submitting"
	args={{
		loading: true
	}}
>
	{#snippet template(args)}
		<ConsentScreen
			consent={consentAcmePortal}
			loading={args.loading}
			onconsent={args.onconsent}
			oncancel={args.oncancel}
		/>
	{/snippet}
</Story>

<Story
	name="NoEligibleRole"
	args={{ oncancel: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The blocked message must surface.
		await expect(canvas.getByText(/No eligible role for this application/)).toBeVisible();
		// And the app slug must be echoed in the meta block.
		await expect(canvas.getByText('acme-portal')).toBeVisible();
		// Back-to-sign-in lets the user escape the blocked state.
		const back = canvas.getByRole('button', { name: 'Back to sign in' });
		await userEvent.click(back);
		await expect(args.oncancel).toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<ConsentScreen consent={consentNoRoles} oncancel={args.oncancel} />
	{/snippet}
</Story>

<Story
	name="SubmitConsentApproves"
	args={{
		onconsent: fn(),
		oncancel: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const btn = canvas.getByRole('button', { name: 'Authorize' });
		await userEvent.click(btn);
		await expect(args.onconsent).toHaveBeenCalledWith({ role_id: 'production_editor' });
	}}
>
	{#snippet template(args)}
		<ConsentScreen
			consent={consentAcmePortal}
			onconsent={args.onconsent}
			oncancel={args.oncancel}
		/>
	{/snippet}
</Story>

<Story
	name="MultipleRolesSwitchesSelection"
	args={{
		onconsent: fn(),
		oncancel: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Default pre-selection is "viewer" (set via preselectedRoleId in the other story); here we click "editor" first.
		const editorRadio = canvas.getByLabelText('editor', { exact: false });
		await userEvent.click(editorRadio);
		const btn = canvas.getByRole('button', { name: 'Authorize' });
		await userEvent.click(btn);
		await expect(args.onconsent).toHaveBeenCalledWith({ role_id: 'editor' });
	}}
>
	{#snippet template(args)}
		<ConsentScreen
			consent={consentMultipleRoles}
			preselectedRoleId="viewer"
			onconsent={args.onconsent}
			oncancel={args.oncancel}
		/>
	{/snippet}
</Story>

<Story name="ErrorInvalidClient">
	{#snippet template()}
		<ConsentScreen error={errorInvalidClient} oncancel={fn()} onretry={fn()} />
	{/snippet}
</Story>

<Story name="ErrorInvalidRedirect">
	{#snippet template()}
		<ConsentScreen error={errorInvalidRedirect} oncancel={fn()} />
	{/snippet}
</Story>

<Story name="ErrorUnauthorizedClient">
	{#snippet template()}
		<ConsentScreen error={errorUnauthorizedClient} oncancel={fn()} />
	{/snippet}
</Story>

<Story name="ErrorAccessDenied">
	{#snippet template()}
		<ConsentScreen error={errorAccessDenied} oncancel={fn()} onretry={fn()} />
	{/snippet}
</Story>

<Story name="ErrorInvalidRequest">
	{#snippet template()}
		<ConsentScreen error={errorInvalidRequest} oncancel={fn()} />
	{/snippet}
</Story>

<Story name="Branded">
	{#snippet template()}
		<ConsentScreen
			product={brandedProduct.product}
			consent={consentMultipleRoles}
			preselectedRoleId="editor"
			redirectUri="https://app.northwind.example/oauth/callback"
		/>
	{/snippet}
</Story>

<Story name="MCP Single Role">
	{#snippet template()}
		<ConsentScreen mcp={mcpConsentSingle} />
	{/snippet}
</Story>

<Story
	name="MCP Admin Wildcard"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The role label (not the resource URL) is the header identity.
		await expect(
			canvas.getByText(/An MCP client wants to access your account as Admin\./)
		).toBeVisible();
		// The redirect origin is disclosed as what the user approves.
		await expect(
			canvas.getByText(m.apps_redirect_text({ uri: 'http://localhost:4004' }))
		).toBeVisible();
		// The global wildcard reads as human-friendly labels.
		await expect(canvas.getAllByText('All domains').length).toBeGreaterThan(0);
		await expect(canvas.getByText('All actions')).toBeVisible();
	}}
>
	{#snippet template()}
		<ConsentScreen mcp={mcpConsentAdmin} />
	{/snippet}
</Story>

<Story
	name="MCP Multiple Roles"
	args={{ onconsent: fn(), oncancel: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// No pinned role and two roles → the header names the client generically.
		await expect(canvas.getByText(/An MCP client wants to access your account\./)).toBeVisible();
		// The redirect origin is disclosed as what the user approves.
		await expect(
			canvas.getByText(m.apps_redirect_text({ uri: 'http://localhost:4004' }))
		).toBeVisible();
		// Electing a role and authorizing emits the choice.
		const editorRadio = canvas.getByLabelText('Editor', { exact: false });
		await userEvent.click(editorRadio);
		const btn = canvas.getByRole('button', { name: 'Authorize' });
		await userEvent.click(btn);
		await expect(args.onconsent).toHaveBeenCalledWith({ role_id: 'iam.Roles.editor' });
	}}
>
	{#snippet template(args)}
		<ConsentScreen mcp={mcpConsentMultiple} onconsent={args.onconsent} oncancel={args.oncancel} />
	{/snippet}
</Story>

<Story
	name="MCP No Eligible Role"
	args={{ oncancel: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText(/No eligible role for this request/)).toBeVisible();
		const back = canvas.getByRole('button', { name: 'Back to sign in' });
		await userEvent.click(back);
		await expect(args.oncancel).toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<ConsentScreen mcp={mcpConsentNoRoles} oncancel={args.oncancel} />
	{/snippet}
</Story>

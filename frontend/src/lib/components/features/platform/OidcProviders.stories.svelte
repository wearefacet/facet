<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import OidcProviders from './OidcProviders.svelte';
	import type { OidcProviderRow } from './OidcProvidersSource.js';

	const SEED: OidcProviderRow[] = [
		{
			id: '01OIDC1',
			name: 'okta',
			label: 'Okta SSO',
			issuer: 'https://example.okta.com/oauth2/default',
			client_id: 'client-123',
			client_secret: { mode: 'sealed', version: 1, set_at: '2026-01-10T08:00:00Z' },
			domains: ['okta.com'],
			default_role: 'iam.Roles.viewer',
			auto_provision: true,
			scopes: ['openid', 'profile', 'email'],
			enabled: true
		},
		{
			id: '01OIDC2',
			name: 'authentik',
			label: '',
			issuer: 'https://auth.company.dev/application/o/facet',
			client_id: 'client-789',
			client_secret: null,
			domains: [],
			default_role: null,
			auto_provision: false,
			scopes: ['openid'],
			enabled: false
		}
	];

	const { Story } = defineMeta({
		title: 'Components/Features/Platform/OidcProviders',
		component: OidcProviders
	});
</script>

<script lang="ts">
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import ConfirmDialog from '$lib/components/primitives/surfaces/ConfirmDialog.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import { OidcProvidersError } from './OidcProvidersSource.js';
	import * as m from '$lib/paraglide/messages';

	// The component instance — the create dialog opens through the
	// `openCreate()` export (the Create button lives in the page header).
	let instance: OidcProviders;

	// Shared spies — each play clears the ones it asserts on.
	const createSpy = fn(async (_fields: Record<string, unknown>) => {});
	const updateSpy = fn(async (_id: string, _fields: Record<string, unknown>) => {});
	const stageSpy = fn(async (_value: string) => 'sh_stage-handle-1');
	const toggleSpy = fn(async (_row: OidcProviderRow) => {});
	const deleteSpy = fn(async (_row: OidcProviderRow) => {});
	const changedSpy = fn();

	type Callbacks = {
		onCreate: (fields: Record<string, unknown>) => Promise<void>;
		onUpdate: (id: string, fields: Record<string, unknown>) => Promise<void>;
		onStageSecret: (value: string) => Promise<string>;
		onToggle: (row: OidcProviderRow) => Promise<void>;
		onDelete: (row: OidcProviderRow) => Promise<void>;
		onChanged: () => void;
	};

	/** The standard callback set; a story overrides the entries it asserts on. */
	function wiring(overrides: Partial<Callbacks> = {}): Callbacks {
		return {
			onCreate: createSpy,
			onUpdate: updateSpy,
			onStageSecret: stageSpy,
			onToggle: toggleSpy,
			onDelete: deleteSpy,
			onChanged: changedSpy,
			...overrides
		};
	}
</script>

<!--
	The backend round-trips arrive as callback props, so every story runs
	against spies — no backend and no `apiFetch` involved. The create /
	edit dialog renders in place (fixed overlay), so the play functions
	query the story canvas; the confirm dialog portals into
	`document.body`.
-->

<Story
	name="RendersRows"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Okta SSO')).toBeVisible());
		// The slug renders as /name in mono.
		await expect(canvas.getByText('/okta')).toBeVisible();
		await expect(canvas.getByText('/authentik')).toBeVisible();
		await expect(canvas.getByText('https://example.okta.com/oauth2/default')).toBeVisible();
		// A row without domains shows the em-dash placeholder.
		await expect(canvas.getByText('—')).toBeVisible();
		// The JIT badge rides the auto-provision row only.
		await expect(canvas.getByText(m.configure_oidc_jit_badge())).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders rows={SEED} bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyState"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText(m.configure_oidc_empty())).toBeVisible());
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders rows={[]} bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<Story
	name="LoadingState"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText(m.common_loading())).toBeVisible());
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders loading bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<Story
	name="EditDialogPrefillsRow"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Open the edit dialog from the first row.
		await userEvent.click(
			canvas.getAllByRole('button', { name: m.common_edit() })[0] as HTMLElement
		);
		const dialog = canvas.getByRole('dialog');
		await expect(
			within(dialog).getByRole('heading', { name: m.configure_oidc_edit_title() })
		).toBeVisible();
		// The name is prefilled and immutable in edit mode.
		const name = within(dialog).getByLabelText(m.configure_oidc_field_name()) as HTMLInputElement;
		await expect(name).toHaveValue('okta');
		await expect(name).toBeDisabled();
		const issuer = within(dialog).getByLabelText(
			m.configure_oidc_field_issuer()
		) as HTMLInputElement;
		await expect(issuer).toHaveValue('https://example.okta.com/oauth2/default');
		// The list fields re-join into comma-separated text.
		const domains = within(dialog).getByLabelText(
			m.configure_oidc_field_domains()
		) as HTMLInputElement;
		await expect(domains).toHaveValue('okta.com');
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders rows={SEED} bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<Story
	name="CreateDialogOpensEmpty"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await instance.openCreate();
		const dialog = canvas.getByRole('dialog');
		await expect(
			within(dialog).getByRole('heading', { name: m.configure_oidc_create() })
		).toBeVisible();
		const name = within(dialog).getByLabelText(m.configure_oidc_field_name()) as HTMLInputElement;
		await expect(name).toBeEnabled();
		await expect(name).toHaveValue('');
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders rows={SEED} bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<!-- B-133: the page's header wiring — a bound instance ref and a guarded
	openCreate() call. The click must open the dialog; before the bind, the
	ref stayed undefined and the button reached nothing. -->
<Story
	name="CreateButtonOpensDialog"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: m.configure_oidc_create() }));
		const dialog = canvas.getByRole('dialog');
		await expect(
			within(dialog).getByRole('heading', { name: m.configure_oidc_create() })
		).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<Button
				label={m.configure_oidc_create()}
				variant="primary"
				onclick={() => instance?.openCreate()}
			/>
			<OidcProviders rows={SEED} bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<Story
	name="CreateSaveEmitsFields"
	play={async ({ canvasElement }) => {
		createSpy.mockClear();
		changedSpy.mockClear();
		const canvas = within(canvasElement);
		await instance.openCreate();
		const dialog = canvas.getByRole('dialog');
		await userEvent.type(within(dialog).getByLabelText(m.configure_oidc_field_name()), 'team-oidc');
		await userEvent.type(
			within(dialog).getByLabelText(m.configure_oidc_field_issuer()),
			'https://id.example.com'
		);
		await userEvent.type(
			within(dialog).getByLabelText(m.configure_oidc_field_client_id()),
			'cid-1'
		);
		// Mixed case and spaces — save trims, lowercases, and splits.
		await userEvent.type(
			within(dialog).getByLabelText(m.configure_oidc_field_domains()),
			'Team.Example.com, other.io'
		);
		await userEvent.click(within(dialog).getByRole('button', { name: m.common_save() }));
		await waitFor(() => expect(createSpy).toHaveBeenCalledTimes(1));
		await expect(createSpy).toHaveBeenCalledWith({
			name: 'team-oidc',
			issuer: 'https://id.example.com',
			client_id: 'cid-1',
			domains: ['team.example.com', 'other.io'],
			scopes: [],
			auto_provision: false,
			enabled: true
		});
		// An untouched secret stays out of the body; the page reloads.
		await expect(stageSpy).not.toHaveBeenCalled();
		await expect(changedSpy).toHaveBeenCalledTimes(1);
		// The dialog closed on success.
		await expect(canvas.queryByRole('dialog')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders rows={[]} bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<Story
	name="EditSaveStagesSecret"
	play={async ({ canvasElement }) => {
		updateSpy.mockClear();
		stageSpy.mockClear();
		changedSpy.mockClear();
		const canvas = within(canvasElement);
		await userEvent.click(
			canvas.getAllByRole('button', { name: m.common_edit() })[0] as HTMLElement
		);
		const dialog = canvas.getByRole('dialog');
		await userEvent.type(
			within(dialog).getByLabelText(m.configure_oidc_field_secret()),
			'sk-live-9f8'
		);
		await userEvent.click(within(dialog).getByRole('button', { name: m.common_save() }));
		// The plaintext stages out-of-band; the PATCH carries the handle.
		await waitFor(() => expect(stageSpy).toHaveBeenCalledTimes(1));
		await expect(stageSpy).toHaveBeenCalledWith('sk-live-9f8');
		await waitFor(() => expect(updateSpy).toHaveBeenCalledTimes(1));
		await expect(updateSpy).toHaveBeenCalledWith(
			'01OIDC1',
			expect.objectContaining({ client_secret: 'sh_stage-handle-1' })
		);
		// The plaintext reaches neither the patch nor the DOM.
		await expect(within(document.body).queryByText('sk-live-9f8')).toBeNull();
		await expect(changedSpy).toHaveBeenCalledTimes(1);
		await expect(canvas.queryByRole('dialog')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders rows={SEED} bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<Story
	name="SaveErrorKeepsDialogOpen"
	play={async ({ canvasElement }) => {
		createSpy.mockClear();
		const canvas = within(canvasElement);
		await instance.openCreate();
		const dialog = canvas.getByRole('dialog');
		await userEvent.type(within(dialog).getByLabelText(m.configure_oidc_field_name()), 'dup');
		await userEvent.click(within(dialog).getByRole('button', { name: m.common_save() }));
		// The 422 maps to the field error; the dialog stays open for fixes.
		await waitFor(() =>
			expect(within(dialog).getByText('That name is already in use.')).toBeVisible()
		);
		await expect(dialog).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders
				rows={[]}
				bind:this={instance}
				onCreate={fn(async () => {
					throw new OidcProvidersError(422, 'Invalid provider', [
						{ field: 'name', message: 'That name is already in use.', code: null }
					]);
				})}
				onUpdate={updateSpy}
				onStageSecret={stageSpy}
				onToggle={toggleSpy}
				onDelete={deleteSpy}
				onChanged={changedSpy}
			/>
		</div>
	{/snippet}
</Story>

<!-- F05-02: a field-less detail (the Lua issuer rule) has no input to attach
		to. It must render under the 422 headline, not be dropped. -->
<Story
	name="SaveErrorShowsFieldlessDetail"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await instance.openCreate();
		const dialog = canvas.getByRole('dialog');
		await userEvent.type(
			within(dialog).getByLabelText(m.configure_oidc_field_name()),
			'bad-issuer'
		);
		await userEvent.click(within(dialog).getByRole('button', { name: m.common_save() }));
		// The headline and the field-less detail both render in the form area.
		await waitFor(() => expect(within(dialog).getByText('Script validation failed')).toBeVisible());
		await expect(
			within(dialog).getByText(
				'issuer must be an absolute https URL — plain http is allowed only on a loopback host (localhost, 127.0.0.1, ::1)'
			)
		).toBeVisible();
		await expect(dialog).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders
				rows={[]}
				bind:this={instance}
				onCreate={fn(async () => {
					throw new OidcProvidersError(422, 'Script validation failed', [
						{
							field: null,
							message:
								'issuer must be an absolute https URL — plain http is allowed only on a loopback host (localhost, 127.0.0.1, ::1)',
							code: null
						}
					]);
				})}
				onUpdate={updateSpy}
				onStageSecret={stageSpy}
				onToggle={toggleSpy}
				onDelete={deleteSpy}
				onChanged={changedSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ToggleEmitsRow"
	play={async ({ canvasElement }) => {
		toggleSpy.mockClear();
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getAllByLabelText(m.configure_oidc_enabled())[0] as HTMLElement);
		await waitFor(() => expect(toggleSpy).toHaveBeenCalledTimes(1));
		await expect(toggleSpy).toHaveBeenCalledWith(SEED[0]);
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders rows={SEED} bind:this={instance} {...wiring()} />
		</div>
	{/snippet}
</Story>

<Story
	name="DeleteRunsConfirmThenEmits"
	play={async ({ canvasElement }) => {
		deleteSpy.mockClear();
		const canvas = within(canvasElement);
		await userEvent.click(
			canvas.getAllByRole('button', { name: m.common_delete() })[0] as HTMLElement
		);
		// The confirm host portals into document.body; the row button is
		// outside it, so the dialog button is the one inside role=dialog.
		const confirmDialog = await waitFor(() => {
			const el = within(document.body).getByRole('dialog');
			expect(el).toBeVisible();
			return el;
		});
		await userEvent.click(within(confirmDialog).getByRole('button', { name: m.common_delete() }));
		await waitFor(() => expect(deleteSpy).toHaveBeenCalledTimes(1));
		await expect(deleteSpy).toHaveBeenCalledWith(SEED[0]);
	}}
>
	{#snippet template()}
		<div style="min-height: 320px; padding: 16px;">
			<OidcProviders rows={SEED} bind:this={instance} {...wiring()} />
			<!-- The confirm host lives in the root layout in the app; the
			     story must mount it explicitly or confirm() never renders. -->
			<ConfirmDialog />
		</div>
	{/snippet}
</Story>

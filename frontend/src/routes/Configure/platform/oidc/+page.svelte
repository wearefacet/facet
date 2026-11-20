<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import OidcProviders from '$lib/components/features/platform/OidcProviders.svelte';
	import {
		listProviders,
		createProvider,
		updateProvider,
		deleteProvider,
		stageClientSecret,
		OidcProvidersError,
		type OidcProviderRow
	} from '$lib/components/features/platform/OidcProvidersSource.js';
	import { errorMessage as toMessage } from '$lib/datasource/bannerError.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * OIDC identity providers (/Configure/platform/oidc).
	 *
	 * The page loads the provider list and wires the backend round-trips
	 * into `OidcProviders` (see `doc/backend/oidc.md`); the component owns
	 * the list, the create / edit dialog, and the confirm flows. The
	 * client secret is staged out-of-band at save — the request carries
	 * the single-use handle, never the plaintext. Toggle and delete
	 * failures show on the page banner; a `422` from the write gate
	 * renders per field inside the dialog. Non-admin callers get the
	 * standard `403` surface from the document routes.
	 */

	let rows = $state<OidcProviderRow[]>([]);
	let loading = $state(true);
	let errorMessage: string | undefined = $state(undefined);
	let errorStatus: number | undefined = $state(undefined);

	// The component instance — the Create button opens the dialog through
	// the `openCreate()` export (B-133: the ref must be bound, the optional
	// call stays guarded until the component mounts).
	let oidc = $state<OidcProviders>();

	async function load() {
		loading = true;
		errorMessage = undefined;
		errorStatus = undefined;
		try {
			rows = await listProviders();
		} catch (e) {
			rows = [];
			if (e instanceof OidcProvidersError) {
				errorStatus = e.status;
				errorMessage = toMessage(e, m.configure_oidc_load_fallback());
			} else {
				errorMessage = toMessage(e, m.configure_oidc_load_fallback());
			}
		} finally {
			loading = false;
		}
	}

	$effect(() => {
		void load();
	});

	function handleCreate(fields: Record<string, unknown>): Promise<void> {
		return createProvider(fields);
	}

	function handleUpdate(id: string, fields: Record<string, unknown>): Promise<void> {
		return updateProvider(id, fields);
	}

	function handleStageSecret(value: string): Promise<string> {
		return stageClientSecret(value);
	}

	function handleChanged() {
		void load();
	}

	async function handleToggle(row: OidcProviderRow) {
		try {
			await updateProvider(row.id, { enabled: !row.enabled });
			row.enabled = !row.enabled;
		} catch (e) {
			errorMessage = toMessage(e, m.configure_oidc_save_fallback());
		}
	}

	async function handleDelete(row: OidcProviderRow) {
		try {
			await deleteProvider(row.id);
			await load();
		} catch (e) {
			errorMessage = toMessage(e, m.configure_oidc_save_fallback());
		}
	}
</script>

<svelte:head>
	<title>{m.configure_oidc_page_title()}</title>
</svelte:head>

<PageHeader title={m.configure_oidc_title()} subtitle={m.configure_oidc_subtitle()}>
	{#snippet actions()}
		<Button
			label={m.configure_oidc_create()}
			onclick={() => oidc?.openCreate()}
			variant="primary"
		/>
	{/snippet}
</PageHeader>

{#if errorMessage}
	<p class="load-error" role="alert" data-status={errorStatus}>{errorMessage}</p>
{/if}

<div class="page-body">
	<OidcProviders
		bind:this={oidc}
		{rows}
		{loading}
		onCreate={handleCreate}
		onUpdate={handleUpdate}
		onStageSecret={handleStageSecret}
		onToggle={handleToggle}
		onDelete={handleDelete}
		onChanged={handleChanged}
	/>
</div>

<style>
	.page-body {
		padding: 0 32px 32px;
	}

	.load-error {
		margin: 0 32px 16px;
		font-size: 12.5px;
		color: var(--danger);
		background: var(--danger-weak);
		border-radius: var(--r-sm);
		padding: 8px 10px;
	}
</style>

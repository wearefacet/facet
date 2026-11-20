<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import SystemSettingsForm from '$lib/components/features/platform/SystemSettingsForm.svelte';
	import Badge from '$lib/components/primitives/data/Badge.svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import {
		getSystemSettings,
		saveSystemSettings,
		stageSystemSecret,
		sendTestMail,
		testAssistant,
		SystemSettingsError
	} from '$lib/components/features/platform/SystemSettingsSource.js';
	import { errorMessage as toMessage } from '$lib/datasource/bannerError.js';
	import { page } from '$app/state';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Platform system settings (/Configure/platform/settings).
	 *
	 * Operator surface for the runtime platform configuration — the
	 * assistant connection, the mail connector, artifact serving, and data
	 * retention. The page loads the effective snapshot
	 * (`GET /api/SystemSettings`), hands it to the chaptered form, and saves
	 * through the standard document update route (sparse PATCH: dirty
	 * fields + explicit nulls only). Secret rotation rides the same save:
	 * the form stages each typed plaintext out-of-band and puts the handle
	 * in the patch — the plaintext never enters the PATCH body. The backend
	 * re-checks everything — RBAC, the write-time gate, secret adoption —
	 * and fans the change out to every process.
	 *
	 * A `422` from the write-time gate carries the structured field errors;
	 * the banner shows the messages with their paths so the admin can see
	 * which knob the gate rejected.
	 */

	let data = $state<{ values: Record<string, unknown>; pinned: string[] } | null>(null);
	let loading: boolean = $state(true);
	let errorMessage: string | undefined = $state(undefined);
	let errorStatus: number | undefined = $state(undefined);

	let saving: boolean = $state(false);
	let saveBanner: string | null = $state(null);
	let savedNote: boolean = $state(false);
	let fieldErrors: { field: string | null; message: string; code: string | null }[] = $state([]);

	async function load() {
		loading = true;
		errorMessage = undefined;
		errorStatus = undefined;
		try {
			data = await getSystemSettings();
		} catch (e) {
			data = null;
			if (e instanceof SystemSettingsError) {
				errorStatus = e.status;
				errorMessage = e.status === 403 ? m.system_settings_forbidden() : e.message;
			} else {
				errorMessage = toMessage(e, m.system_settings_load_error());
			}
		} finally {
			loading = false;
		}
	}

	$effect(() => {
		void load();
	});

	async function handleSave(patch: Record<string, unknown>) {
		if (Object.keys(patch).length === 0) return;
		saving = true;
		saveBanner = null;
		savedNote = false;
		fieldErrors = [];
		try {
			await saveSystemSettings(patch);
			await load(); // re-read the effective snapshot (pins may have changed)
			savedNote = true;
		} catch (e) {
			if (e instanceof SystemSettingsError && e.status === 422) {
				fieldErrors = e.fieldErrors ?? [];
				saveBanner =
					fieldErrors.map((f) => f.message).join(' · ') || m.system_settings_save_error();
			} else if (e instanceof SystemSettingsError && e.status === 403) {
				saveBanner = m.system_settings_forbidden();
			} else {
				saveBanner = toMessage(e, m.system_settings_save_error());
			}
		} finally {
			saving = false;
		}
	}

	async function handleStageSecret(path: string, value: string): Promise<string> {
		return stageSystemSecret(path, value);
	}

	// The recipient defaults to the signed-in account's address — the one
	// inbox the operator is certain to read.
	const testRecipient = $derived(page.data.account?.email ?? '');

	// Drives the provisioning-roles reference picker (iam.Roles search).
	// Same-origin base, like the layout's sidebar driver.
	const driver = new DocumentDataDriver('');
</script>

<svelte:head>
	<title>{m.system_settings_page_title()}</title>
</svelte:head>

{#snippet errorRow(message: string, retry: boolean)}
	<div class="state state-error">
		<p>{message}</p>
		{#if retry}
			<button class="retry-btn" type="button" onclick={load}>{m.common_retry()}</button>
		{/if}
	</div>
{/snippet}

<div class="page">
	<PageHeader
		title={m.system_settings_page_header()}
		subtitle={m.system_settings_page_subtitle()}
	/>

	{#if errorMessage && errorStatus === 403}
		{@render errorRow(errorMessage, false)}
	{:else if errorMessage}
		{@render errorRow(errorMessage, true)}
	{:else if loading || !data}
		<div class="state">
			<p>{m.common_loading()}</p>
		</div>
	{:else}
		<div class="body">
			{#if saveBanner}
				<div class="banner banner-error" role="alert">
					<span>{saveBanner}</span>
					{#each fieldErrors as fe (fe.field ?? fe.message)}
						{#if fe.field}
							<Badge label={fe.field} variant="danger" size="sm" />
						{/if}
					{/each}
				</div>
			{:else if savedNote}
				<div class="banner banner-ok" role="status">{m.system_settings_saved()}</div>
			{/if}

			<SystemSettingsForm
				{data}
				{saving}
				onSave={handleSave}
				onStageSecret={handleStageSecret}
				onTestMail={sendTestMail}
				onTestAssistant={testAssistant}
				defaultTestRecipient={testRecipient}
				{driver}
			/>
		</div>
	{/if}
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 1120px;
		margin: 0 auto;
	}

	.body {
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.state {
		padding: 24px;
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		background: var(--surface);
	}

	.state p {
		margin: 0;
		font-size: 13px;
		color: var(--text-2);
	}

	.state-error p {
		color: var(--danger);
	}

	.retry-btn {
		margin-top: 12px;
		padding: 6px 14px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.retry-btn:hover {
		background: var(--sunken);
	}

	.banner {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 8px;
		padding: 10px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
	}

	.banner-error {
		border: 1px solid var(--danger);
		background: var(--danger-weak);
		color: var(--danger);
	}

	.banner-ok {
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text-2);
	}
</style>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { can } from '$lib/permissions.svelte';
	import type { AppContent } from '$lib/app/appTypes';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import StringListEditor from '$lib/components/primitives/forms/StringListEditor.svelte';
	import * as m from '$lib/paraglide/messages';
	import {
		toSlug,
		validateOrigin,
		validateRedirectUri,
		redirectOriginAllowed
	} from '$lib/app/appValidation';

	/**
	 * SetupForm — step 1 of the new-app wizard. The app gets a name, a
	 * derived slug, an owner, and its allowed origins and redirect URIs.
	 *
	 * One grouped `$state` object holds the eight form fields. The slug
	 * auto-derives from the name until the user edits it. A debounced
	 * uniqueness check runs through the `checkSlug` callback. Both client
	 * types edit the origins and the redirect URIs here — a `confidential`
	 * app signs in through a browser too. The sign-in endpoint itself is
	 * shown only on the credentials step after publish — it carries the app's
	 * client id, which does not exist yet at setup time (B-200).
	 *
	 * On a loaded draft (back-navigation from a later step) the slug is
	 * immutable: the input renders disabled and the Continue payload omits
	 * it — the update hook rejects any patch that carries the key.
	 *
	 * The page owns the save and the navigation: `onContinue` receives the
	 * wire payload, the page writes the draft, and the page shows the error
	 * banner. Stories pass synthetic callbacks and a mock driver.
	 */

	let {
		app,
		issuerBase: _issuerBase,
		currentAccount,
		saving = false,
		checkSlug,
		onContinue,
		driver = new DocumentDataDriver('')
	}: {
		/** The loaded draft, or null on a fresh setup. */
		app: { meta: { id: string }; data: AppContent } | null;
		/** The instance's public base URL (unused here — the sign-in endpoint
		 * shows on the credentials step once the client id exists, B-200). */
		issuerBase: string;
		/** The signed-in account. Seeds the owner default on a fresh setup. */
		currentAccount: { id: string; displayName: string } | null;
		/** True while the page writes the draft (disables Continue). */
		saving?: boolean;
		/** Returns true when the candidate slug is already taken. */
		checkSlug: (slug: string) => Promise<boolean>;
		/** Carries the payload to the page, which saves it and moves on. */
		onContinue: (payload: Partial<AppContent>) => Promise<void>;
		/** Data driver for the owner picker — a mock in stories. */
		driver?: DataDriver;
	} = $props();

	// ── Form state ───────────────────────────────────────────────────────
	// One grouped object holds the eight fields the page used to keep as
	// loose $state binds. Seeded from the loaded draft on back-navigation,
	// or from the `preset` query param on a fresh setup. User edits stay
	// local until Continue hands the payload to the page.
	type SetupValues = {
		displayName: string;
		slug: string;
		slugManuallyEdited: boolean;
		description: string;
		ownerId: string;
		clientType: 'public' | 'confidential';
		allowedOrigins: string[];
		redirectUris: string[];
	};

	let values = $state<SetupValues>({
		displayName: '',
		slug: '',
		slugManuallyEdited: false,
		description: '',
		ownerId: '',
		clientType: 'public',
		allowedOrigins: [],
		redirectUris: []
	});

	// Seed from the loaded draft (initial load and after invalidateAll on
	// Back/Continue). Do not read the form fields here — the effect would
	// join them and re-run on each keystroke, which erases the user's
	// input. Read the `app` prop only.
	$effect(() => {
		const appData = app?.data;
		const preset = presetFromUrl();
		if (appData) {
			values.displayName = appData.name ?? '';
			values.slug = appData.slug ?? '';
			values.slugManuallyEdited = true; // the loaded draft already has its slug
			values.description = appData.description ?? '';
			values.ownerId = appData.owner_id ?? '';
			values.clientType = appData.client_type ?? 'public';
			values.allowedOrigins = Array.isArray(appData.allowed_origins)
				? [...appData.allowed_origins]
				: [];
			values.redirectUris = Array.isArray(appData.redirect_uris) ? [...appData.redirect_uris] : [];
		} else if (preset) {
			values.clientType = preset.clientType;
		}
	});

	// Default the owner to the current account on a fresh setup (no draft
	// yet, no owner set). Runs when the account resolves, and only while
	// the owner field is still empty.
	$effect(() => {
		const u = currentAccount;
		if (u && !values.ownerId && !app) {
			values.ownerId = u.id;
		}
	});

	// The slug auto-derives from the name until the user edits it. After
	// that, the slug stays as typed.
	$effect(() => {
		if (!values.slugManuallyEdited) {
			values.slug = toSlug(values.displayName);
		}
	});

	// `bind:value` cannot filter keystrokes, so the input cleans its own
	// value here (see workflow doc: "bind:value vs. oninput sanitisation").
	function onSlugInput(e: Event): void {
		const t = e.target as HTMLInputElement;
		const clean = t.value
			.toLowerCase()
			.replace(/[^a-z0-9-]/g, '')
			.slice(0, 64);
		t.value = clean;
		values.slug = clean;
		values.slugManuallyEdited = true;
	}

	function editSlug(): void {
		values.slugManuallyEdited = true;
	}

	// ── Slug uniqueness check ────────────────────────────────────────────
	// Debounced read through `checkSlug`. Skipped while the slug matches
	// the loaded draft's own slug (back-navigation to edit other fields).
	let slugTaken = $state(false);
	let precheckTimer: ReturnType<typeof setTimeout> | undefined;
	async function precheckSlug(value: string): Promise<void> {
		if (precheckTimer) clearTimeout(precheckTimer);
		if (!value || value === (app?.data?.slug ?? '')) {
			slugTaken = false;
			return;
		}
		precheckTimer = setTimeout(async () => {
			try {
				slugTaken = await checkSlug(value);
			} catch {
				slugTaken = false;
			}
		}, 250);
	}

	// Run the check again whenever the slug changes.
	$effect(() => {
		void precheckSlug(values.slug);
	});

	const slugError = $derived(
		!values.slug
			? m.configure_apps_slug_required()
			: slugTaken
				? m.configure_apps_slug_taken()
				: undefined
	);

	const canContinue = $derived(
		Boolean(values.slug && values.displayName && !slugTaken && !slugError) &&
			can('app.App', 'create')
	);

	// ── Preset ───────────────────────────────────────────────────────────
	// The `preset` query param sets the client type on a fresh setup:
	// `external` selects public; `backend` (alias `confidential`) selects
	// confidential. Read at seed time, like the page did.
	function presetFromUrl(): { clientType: 'public' | 'confidential' } | null {
		if (typeof location === 'undefined') return null;
		const p = new URLSearchParams(location.search).get('preset');
		switch (p) {
			case 'backend':
			case 'confidential':
				return { clientType: 'confidential' };
			case 'external':
				return { clientType: 'public' };
			default:
				return null;
		}
	}

	// ── Continue ─────────────────────────────────────────────────────────
	// Build the wire payload and hand it to the page. The page decides
	// create vs. update, then moves to the permissions step. `slug` rides
	// the create payload only: the update hook rejects any patch that
	// carries the key (immutable after creation), so a back-navigation
	// save — fixing the origins or the redirect URIs from the review
	// checklist — must not include it.
	async function continueSave(): Promise<void> {
		const payload: Partial<AppContent> = {
			name: values.displayName,
			description: values.description,
			owner_id: values.ownerId || undefined,
			client_type: values.clientType,
			allowed_origins: values.allowedOrigins,
			redirect_uris: values.redirectUris
		};
		if (!app) payload.slug = values.slug;
		await onContinue(payload);
	}
</script>

<section class="card">
	<div class="field">
		<label class="field-label" for="app-name">{m.configure_domains_display_name_label()}</label>
		<input
			id="app-name"
			type="text"
			class="field-input"
			placeholder={m.configure_apps_name_placeholder()}
			bind:value={values.displayName}
			aria-describedby="slug-helper"
		/>
		<div id="slug-helper" class="field-row">
			<span class="field-helper">{m.configure_apps_address_prefix()}</span>
			<code class="slug-display">{values.slug || 'app-slug'}</code>
			{#if !values.slugManuallyEdited}
				<button type="button" class="link-button" onclick={editSlug}>{m.common_edit()}</button>
			{/if}
			<span class="field-muted">{m.configure_apps_slug_permanent()}</span>
		</div>
	</div>

	<!-- After the user clicks "Edit", the manual slug input shows here.
	     A loaded draft (back-navigation from a later step) renders it
	     disabled: the slug is immutable after creation, and the update
	     hook would refuse a patch that carries it. -->
	{#if values.slugManuallyEdited}
		<div class="field">
			<label class="field-label" for="app-slug">{m.configure_apps_slug_label()}</label>
			<input
				id="app-slug"
				type="text"
				class="field-input"
				placeholder={m.configure_apps_slug_placeholder()}
				value={values.slug}
				oninput={onSlugInput}
				disabled={app !== null}
				aria-invalid={slugTaken || Boolean(slugError) || undefined}
				aria-describedby="slug-validation"
			/>
			<span id="slug-validation" class="field-helper" class:field-error={slugTaken || slugError}>
				{#if slugTaken}
					{m.configure_apps_slug_taken()}
				{:else if !values.slug}
					{m.configure_apps_slug_required()}
				{:else}
					{m.configure_apps_slug_helper()}
				{/if}
			</span>
		</div>
	{/if}

	<div class="field">
		<label class="field-label" for="app-desc">
			{m.common_description()}
			<span class="field-muted">{m.configure_apps_desc_muted()}</span>
		</label>
		<textarea
			id="app-desc"
			class="field-input field-textarea"
			bind:value={values.description}
			rows="2"
			placeholder={m.configure_apps_desc_placeholder()}></textarea>
	</div>

	<div class="field">
		<ReferencePicker
			label={m.configure_apps_owner_label()}
			bind:value={values.ownerId}
			doctype="iam.Account"
			{driver}
			placeholder={m.configure_apps_owner_placeholder()}
			helper={m.configure_apps_owner_helper()}
		/>
	</div>

	<div class="divider"></div>

	<div class="field">
		<StringListEditor
			bind:values={values.allowedOrigins}
			label={m.configure_apps_allowed_origins_label()}
			placeholder="https://app.example.com"
			validator={validateOrigin}
			helper={m.configure_apps_origins_wizard_helper()}
		/>
		<div class="origin-quick-add">
			<button
				type="button"
				class="quick-add-button"
				onclick={() => {
					if (!values.allowedOrigins.includes('http://localhost:5173')) {
						values.allowedOrigins.push('http://localhost:5173');
					}
				}}
			>
				+ localhost:5173
			</button>
		</div>
	</div>

	<div class="field">
		<StringListEditor
			bind:values={values.redirectUris}
			label={m.configure_apps_redirect_uris_label()}
			placeholder="https://app.example.com/oauth/callback"
			validator={validateRedirectUri}
			helper={m.configure_apps_redirect_wizard_helper()}
		/>
		<!-- Origin check per URI: the ok line shows when the URI's origin
					 sits in allowed_origins. -->
		{#each values.redirectUris as uri (uri)}
			{#if redirectOriginAllowed(uri, values.allowedOrigins)}
				<div class="redirect-ok">{m.configure_apps_redirect_ok()}</div>
			{:else}
				<div class="redirect-warn">{m.configure_apps_redirect_warn()}</div>
			{/if}
		{/each}
	</div>
</section>

<footer class="step-footer">
	<span class="footer-hint">{m.configure_apps_draft_hint()}</span>
	<Button variant="primary" disabled={!canContinue || saving} onclick={continueSave}>
		{saving ? m.common_saving() : m.configure_apps_continue()}
	</Button>
</footer>

<style>
	.card {
		display: flex;
		flex-direction: column;
		gap: 18px;
		padding: 16px 20px;
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
	}

	.field {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	.field-label {
		font-size: 13px;
		font-weight: 500;
		color: var(--text-2);
	}

	.field-input {
		font: inherit;
		font-size: 13px;
		padding: 9px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.field-input:focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.field-textarea {
		min-height: 60px;
		resize: vertical;
		font-family: var(--font-sans);
	}

	.field-row {
		display: flex;
		align-items: center;
		gap: 7px;
		flex-wrap: wrap;
		font-size: 12.5px;
		color: var(--text-3);
	}

	.field-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.field-muted {
		color: var(--text-3);
		font-weight: 400;
	}

	.field-error {
		color: var(--danger);
	}

	.slug-display {
		font-family: var(--font-mono);
		font-size: 12px;
		background: var(--surface);
		padding: 2px 7px;
		border-radius: 4px;
	}

	.link-button {
		background: none;
		border: none;
		color: var(--accent);
		font: inherit;
		font-size: 12.5px;
		cursor: pointer;
		padding: 0;
		text-decoration: underline;
	}

	.divider {
		height: 1px;
		background: var(--border);
		margin: 4px 0;
	}

	.origin-quick-add {
		margin-top: 6px;
	}

	.quick-add-button {
		height: 27px;
		padding: 0 10px;
		font: inherit;
		font-size: 12px;
		color: var(--text-2);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		cursor: pointer;
	}

	.quick-add-button:hover {
		border-color: var(--accent);
		color: var(--text);
	}

	.redirect-ok {
		font-size: 12.5px;
		color: var(--ok, #16a34a);
		margin-top: 4px;
	}

	.redirect-warn {
		font-size: 12.5px;
		color: var(--warn, #d97706);
		margin-top: 4px;
	}

	.step-footer {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 10px;
		padding-top: 16px;
		border-top: 1px solid var(--border);
	}

	.footer-hint {
		font-size: 12.5px;
		color: var(--text-3);
	}
</style>

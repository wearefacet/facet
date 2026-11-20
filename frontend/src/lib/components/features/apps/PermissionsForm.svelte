<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import type { AppContent, AppGrant, DoctypeCatalogueEntry } from '$lib/app/appTypes';
	import {
		missingRequiredActions,
		rolePermissionsFromContent,
		type RolePermissionInput
	} from '$lib/authorization/grantUsable.js';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import AppGrantsEditor from '$lib/components/features/configure/AppGrantsEditor.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * PermissionsForm — step 2 of the new-app wizard. Renders the
	 * AppGrantsEditor in `wizard` mode over a local `grants` `$state` array.
	 *
	 * A backend (`confidential`) app also picks its service role here: the
	 * service account authenticates as exactly that role, so the effective
	 * permission is the app's grants ∩ the role. Continue stays disabled
	 * until the role is picked. Public apps keep the grants-only behaviour.
	 *
	 * When the picked role misses a required grant action, a non-blocking
	 * warning names the gap — the runtime would answer 401 on every route.
	 * When the picked role's connectivity excludes the `api` channel, a second
	 * non-blocking warning marks it: key issuance refuses that role with 422.
	 * Continue is never blocked: the warnings are advice, not a gate.
	 *
	 * The page owns the save and the navigation: `onContinue` receives the
	 * wire payload, the page writes the draft, and the page shows the error
	 * banner. Stories pass synthetic callbacks and a mock driver.
	 */

	let {
		app,
		catalogue,
		saving = false,
		onBack,
		onContinue,
		driver = new DocumentDataDriver('')
	}: {
		/** The loaded draft document (id + content), seeded from. */
		app: { meta: { id: string }; data: AppContent };
		/** The doctype catalogue the grants editor renders. */
		catalogue: DoctypeCatalogueEntry[];
		/** True while the page writes the draft (disables Continue). */
		saving?: boolean;
		/** Moves the wizard back to the setup step. */
		onBack: () => void;
		/** Carries the payload to the page, which saves it and moves on. */
		onContinue: (payload: Partial<AppContent>) => Promise<void>;
		/** Data driver for the service-role picker — a mock in stories. */
		driver?: DataDriver;
	} = $props();

	// ── Grants draft ──────────────────────────────────────────────────────
	// `grants` is an array-typed field on `app.App`, but an empty array can
	// round-trip from the Lua lifecycle hook as a non-iterable JSON shape
	// (e.g. `{}`). `?? []` only guards null/undefined, so coerce explicitly
	// before cloning into local state — otherwise the editor's `.find()`
	// calls throw.
	let grants = $state<AppGrant[]>([]);
	let lastGrantsJson = '';
	$effect(() => {
		const raw = Array.isArray(app.data.grants) ? app.data.grants : [];
		const json = JSON.stringify(raw);
		// Guard: only re-clone when the source content actually changes, so an
		// unrelated re-render of `app` (same data, new identity) does not
		// clobber an in-flight local edit.
		if (json !== lastGrantsJson) {
			lastGrantsJson = json;
			grants = JSON.parse(json) as AppGrant[];
		}
	});

	// ── Service role (backend apps) ──────────────────────────────────────
	// Local edit state, seeded from the document. The plain-`let` shadow stops
	// the seed effect from re-running on its own write (workflow doc: the
	// equality-guard trap) and from clobbering an in-flight local edit when
	// `app` re-renders with unchanged data.
	const isConfidential = $derived(app.data.client_type === 'confidential');
	let serviceRoleId = $state('');
	let lastSeededServiceRole = '';
	$effect(() => {
		const seeded = app.data.service_role_id ?? '';
		if (seeded !== lastSeededServiceRole) {
			lastSeededServiceRole = seeded;
			serviceRoleId = seeded;
		}
	});

	// ── Role permission lines (backend apps) ─────────────────────────────
	// The picker carries only ids and labels, so the selected role's
	// `permissions` array loads here through the same driver. It stays
	// `undefined` until the load lands — an unknown permission set must not
	// raise a false alarm. The seq guard drops results from a superseded pick.
	let rolePermissions = $state<RolePermissionInput[] | undefined>(undefined);
	// The same read answers the connectivity check: a role whose list
	// excludes `api` cannot carry a service key (issuance refuses with 422).
	// `undefined` while loading — an unknown list must not raise a false
	// alarm either.
	let roleConnectivity = $state<string[] | undefined>(undefined);
	let roleLoadSeq = 0;
	$effect(() => {
		const roleId = serviceRoleId;
		const activeDriver = driver;
		if (!roleId) {
			roleLoadSeq += 1;
			rolePermissions = undefined;
			roleConnectivity = undefined;
			return;
		}
		const my = ++roleLoadSeq;
		activeDriver
			.domain('iam')
			.doctype('Roles')
			.doc(roleId)
			.show()
			.then((res) => {
				if (my !== roleLoadSeq) return; // superseded by a newer pick
				rolePermissions = rolePermissionsFromContent(res?.data);
				const channels = res?.data?.connectivity;
				roleConnectivity = Array.isArray(channels)
					? channels.filter((c): c is string => typeof c === 'string')
					: [];
			})
			.catch(() => {
				if (my !== roleLoadSeq) return;
				rolePermissions = undefined;
				roleConnectivity = undefined;
			});
	});

	// The required grant actions the picked role does not cover — the
	// setup-time mirror of the runtime check in `src/rbac/grant_resolver.cr`.
	// Empty until a role is picked, its permissions are loaded, and the
	// grants are non-empty. Recomputes on every grants or role change.
	const roleGrantsGap = $derived.by(() => {
		if (!isConfidential || !serviceRoleId || grants.length === 0) return [];
		if (!rolePermissions) return [];
		return missingRequiredActions(grants, rolePermissions);
	});

	// The picked role cannot carry a service key: its connectivity list
	// excludes the `api` channel, so key issuance refuses with 422. Warning
	// only — the operator may still save the draft and fix the role.
	const roleMissingApi = $derived(
		Boolean(isConfidential && serviceRoleId) &&
			roleConnectivity !== undefined &&
			!roleConnectivity.includes('api')
	);

	async function continueSave(): Promise<void> {
		const payload: Partial<AppContent> = { grants };
		if (isConfidential) payload.service_role_id = serviceRoleId;
		await onContinue(payload);
	}
</script>

{#if isConfidential}
	<div class="role-picker">
		<ReferencePicker
			label={m.configure_apps_service_role_label()}
			bind:value={serviceRoleId}
			doctype="iam.Roles"
			{driver}
			placeholder={m.configure_apps_service_role_placeholder()}
			helper={m.configure_apps_service_role_helper()}
		/>
		{#if roleGrantsGap.length > 0}
			<p class="role-gap" role="status">
				{m.apps_role_not_usable_body({ missing: roleGrantsGap.join(', ') })}
			</p>
		{/if}
		{#if roleMissingApi}
			<p class="role-gap" role="status">
				{m.configure_apps_role_no_api_channel()}
			</p>
		{/if}
	</div>
{/if}

<AppGrantsEditor bind:grants doctypeCatalogue={catalogue} mode="wizard" />

<footer class="step-footer">
	<Button variant="ghost" onclick={onBack}>{m.common_back()}</Button>
	<div class="footer-right">
		{#if isConfidential && !serviceRoleId}
			<span class="footer-hint">{m.configure_apps_pick_service_role()}</span>
		{/if}
		<Button
			variant="primary"
			disabled={saving || (isConfidential && !serviceRoleId)}
			onclick={continueSave}
		>
			{saving ? m.common_saving() : m.configure_apps_continue()}
		</Button>
	</div>
</footer>

<style>
	.role-picker {
		margin-bottom: 14px;
	}

	.role-gap {
		margin-top: 8px;
		padding: 8px 10px;
		border-radius: var(--r-sm);
		background: var(--warn-weak);
		color: var(--warn);
		font-size: 12.5px;
	}

	.step-footer {
		display: flex;
		justify-content: space-between;
		gap: 8px;
		padding-top: 16px;
		border-top: 1px solid var(--border);
	}

	.footer-right {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.footer-hint {
		font-size: 12.5px;
		color: var(--warn, #d97706);
	}
</style>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import ChapterNav from '$lib/components/primitives/surfaces/ChapterNav.svelte';
	import type { Chapter } from '$lib/components/primitives/surfaces/ChapterNav.svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { createChapterScroll } from '$lib/components/primitives/surfaces/chapterScroll.svelte.js';
	import * as m from '$lib/paraglide/messages';
	import { allTimezones } from '$lib/timezones.js';
	import { Bot, Globe, History, KeyRound, Mail, Package, RotateCcw, X } from '@lucide/svelte';
	import Badge from '$lib/components/primitives/data/Badge.svelte';
	import SettingsFieldRow from './SettingsFieldRow.svelte';
	import type { FieldRow } from './SettingsFieldRow.svelte';

	/**
	 * SystemSettingsForm — the grouped runtime-settings surface.
	 *
	 * Renders the Assistant, Mail, Artifacts, and Retention groups from one
	 * flat effective-values map keyed by dot-path (the config-file grammar —
	 * see `doc/backend/system-settings.md`). A sticky chapter rail on the
	 * left links to each group; the active chapter follows the scroll
	 * position, and a click scrolls the chapter into view. Each group
	 * heading carries its chapter icon.
	 *
	 * A field the document currently pins carries an override badge and a
	 * reset-to-file control that puts an explicit `null` into the outgoing
	 * sparse patch; untouched fields stay out of the patch entirely, so a
	 * pinned field the admin did not touch stays pinned on the server.
	 * Secret fields show set/not-set from `pinned` (the sealed slot) and
	 * rotate in the same save: Save stages each typed plaintext
	 * out-of-band, swaps the single-use handle into the form state, and the
	 * patch carries the handle — the plaintext never rides the PATCH. A
	 * failed stage aborts the whole save with the error on the row; the
	 * plaintext stays in the input for retry. Every control carries a
	 * helper line that states what the field does and what an empty value
	 * means.
	 *
	 * The storage adapter is a read-only row: it wires at boot from the
	 * config file, and a runtime switch would strand the existing artifact
	 * bytes in the previous backend.
	 *
	 * The component owns the form-session state; the page owns loading,
	 * saving, and the backend round-trips through the injectable callbacks
	 * (stories pass synthetics).
	 */

	interface SettingsValues {
		values: Record<string, unknown>;
		pinned: string[];
	}

	let {
		data,
		saving = false,
		onSave,
		onStageSecret,
		onTestMail,
		onTestAssistant,
		defaultTestRecipient = '',
		driver = undefined
	}: {
		/** The loaded effective snapshot. */
		data: SettingsValues;
		/** True while the page persists the patch (disables Save). */
		saving?: boolean;
		/** Persists the sparse patch. Throws on failure (the page maps status). */
		onSave: (patch: Record<string, unknown>) => Promise<void>;
		/** Stages one secret plaintext and returns the single-use handle. */
		onStageSecret: (fieldPath: string, value: string) => Promise<string>;
		/** Sends one test email through the saved connector. Throws on failure. */
		onTestMail?: (to: string) => Promise<{ adapter: string; from_address: string; to: string }>;
		/** Sends one probe completion through the saved assistant settings. Throws on failure. */
		onTestAssistant?: () => Promise<{ model: string; endpoint: string; reply: string | null }>;
		/** Initial recipient for the test-email field (the signed-in account's email). */
		defaultTestRecipient?: string;
		/** Data driver for the reference pickers (the provisioning-roles list).
		 *  Absent in stories — the roles block then renders read-only. */
		driver?: DataDriver;
	} = $props();

	// ── Effective values, normalized to editable primitives ────────────
	// The map keys are the dot-paths; unset effective values (null) render
	// as empty inputs. Numbers become strings for the number inputs and are
	// coerced back on save.

	// ── The registered paths (mirror of the backend SPEC registry) ──────

	const STRING_PATHS = [
		'assistant.name',
		'assistant.api_endpoint',
		'assistant.model',
		'assistant.system_prompt',
		'mail.adapter',
		'mail.from_address',
		'mail.from_name',
		'mail.smtp.host',
		'mail.smtp.username',
		'localization.default_timezone',
		'localization.default_language',
		'iam.mfa.type',
		'iam.mfa.enforcement',
		'iam.auth.mode'
	] as const;

	const NUMBER_PATHS = [
		'assistant.max_tokens',
		'assistant.temperature',
		'assistant.max_history',
		'mail.smtp.port',
		'artifact.grant_ttl_seconds',
		'artifact.grant_ttl_media_seconds',
		'artifact.prune_after_days',
		'mutations.retention_days',
		'tombstone.content_retention_days',
		'iam.change_password_expiration'
	] as const;

	const BOOL_PATHS = ['assistant.auto_execute_tools', 'mail.smtp.use_tls'] as const;

	/**
	 * Retention windows: a pinned `0` means "keep forever" — the backend
	 * pass skips. The `bool` slot of a retention field mirrors that state
	 * (checked = keep forever), while `text` holds the editable days.
	 */
	const RETENTION_PATHS: readonly string[] = [
		'artifact.prune_after_days',
		'mutations.retention_days',
		'tombstone.content_retention_days'
	];

	const SECRET_PATHS = ['assistant.api_key', 'mail.smtp.password'] as const;

	const ALL_PATHS: readonly string[] = [
		...STRING_PATHS,
		...NUMBER_PATHS,
		...BOOL_PATHS,
		...SECRET_PATHS
	];

	interface FieldState {
		/** The editable value ('' when unset). Secret fields hold the typed plaintext until Save stages it; the handle after. */
		text: string;
		/** Boolean state for toggles. */
		bool: boolean;
		/** Set when the admin reset the field this session (explicit null in the patch). */
		cleared: boolean;
		/** Set after Save staged the plaintext — `text` then holds the handle, not plaintext. */
		staged: boolean;
	}

	// Seeds EVERY registered path, not just the keys present in `values`:
	// the GET response excludes the secret paths, and a row whose state is
	// undefined would crash on first bind. Secret paths start empty — their
	// set/not-set state comes from `pinned`, never from a value.
	//
	// svelte-ignore state_referenced_locally — the bag seeds a one-time
	// form session keyed to the loaded snapshot; the page re-renders the
	// form after each save (the parent re-fetches and re-keys it).
	function buildState(values: Record<string, unknown>): Record<string, FieldState> {
		const state: Record<string, FieldState> = {};
		for (const path of ALL_PATHS) {
			const value = values[path];
			const retention = RETENTION_PATHS.includes(path);
			state[path] = {
				text: value == null ? '' : String(value),
				bool: retention ? value != null && Number(value) === 0 : value === true,
				cleared: false,
				staged: false
			};
		}
		return state;
	}

	// svelte-ignore state_referenced_locally — see buildState above.
	let fields: Record<string, FieldState> = $state(buildState(data.values));

	// ── Provisioning roles (iam.oidc.provision_roles) ──────────────────
	// The one list-valued knob. Kept outside the FieldState bag: the value
	// is a string array, not a primitive. The stored form (and the patch)
	// is the qualified iam.Roles reference — which IS the role document's
	// own id, so the picker's bare-id pick lands in the right grammar.
	const PROVISION_ROLES_PATH = 'iam.oidc.provision_roles';

	function rolesFromSnapshot(values: Record<string, unknown>): string[] {
		const raw = values[PROVISION_ROLES_PATH];
		return Array.isArray(raw) ? raw.filter((v): v is string => typeof v === 'string') : [];
	}

	// svelte-ignore state_referenced_locally — one-time seed, see `fields`.
	let provisionRoles: string[] = $state(rolesFromSnapshot(data.values));
	let rolesCleared: boolean = $state(false);
	let addRoleValue: string = $state('');

	const originalRoles = $derived(rolesFromSnapshot(data.values));
	const rolesDirty = $derived(
		rolesCleared ||
			provisionRoles.length !== originalRoles.length ||
			provisionRoles.some((role, i) => role !== originalRoles[i])
	);

	function addProvisionRole(value: string) {
		const id = value.trim();
		if (!id || provisionRoles.includes(id)) {
			addRoleValue = '';
			return;
		}
		provisionRoles = [...provisionRoles, id];
		rolesCleared = false;
		addRoleValue = '';
	}

	function removeProvisionRole(id: string) {
		provisionRoles = provisionRoles.filter((role) => role !== id);
	}

	function resetProvisionRoles() {
		rolesCleared = true;
		provisionRoles = [];
	}

	function undoRolesClear() {
		rolesCleared = false;
		provisionRoles = rolesFromSnapshot(data.values);
	}

	// A ReferencePicker pick writes the picked id into the bound `value`.
	// The effect consumes it: add to the list, then re-arm the picker. An
	// empty write (the reset above) is skipped.
	$effect(() => {
		const picked = addRoleValue;
		if (picked) addProvisionRole(picked);
	});

	const isPinned = $derived.by(() => {
		const set = new Set(data.pinned);
		return (path: string) => set.has(path);
	});

	// ── Patch assembly ─────────────────────────────────────────────────
	//
	// Sparse by construction: a field enters the patch only when the admin
	// changed, cleared, or staged it in this session. Cleared fields carry
	// an explicit null (reset-to-file); staged secret fields carry the
	// handle; everything else carries the coerced new value.

	function buildPatch(): Record<string, unknown> {
		const patch: Record<string, unknown> = {};
		const setPath = (path: string, value: unknown) => {
			const segments = path.split('.');
			let node = patch;
			for (let i = 0; i < segments.length - 1; i++) {
				const seg = segments[i];
				if (typeof node[seg] !== 'object' || node[seg] === null) node[seg] = {};
				node = node[seg] as Record<string, unknown>;
			}
			node[segments[segments.length - 1]] = value;
		};

		for (const path of ALL_PATHS) {
			const state = fields[path];
			if (!state) continue;
			if (SECRET_PATHS.includes(path as (typeof SECRET_PATHS)[number])) {
				if (state.cleared) setPath(path, null);
				else if (state.staged && state.text) setPath(path, state.text); // the staged handle
				continue;
			}
			if (state.cleared) {
				setPath(path, null);
				continue;
			}
			if (NUMBER_PATHS.includes(path as (typeof NUMBER_PATHS)[number])) {
				if (state.text === '') continue; // untouched empty — stays out of the patch
				const n = Number(state.text);
				if (!Number.isFinite(n)) continue;
				const original = data.values[path] == null ? null : Number(data.values[path]);
				if (n === original) continue; // unchanged — stays out of the patch
				setPath(path, n);
				continue;
			}
			if (BOOL_PATHS.includes(path as (typeof BOOL_PATHS)[number])) {
				const original = data.values[path] === true;
				if (state.bool !== original) setPath(path, state.bool);
				continue;
			}
			// String paths: only a real change enters the patch, so a save
			// without edits produces an empty diff (the backend treats an
			// empty update as a no-op).
			const original = data.values[path] == null ? '' : String(data.values[path]);
			if (state.text !== original) setPath(path, state.text);
		}
		// The provisioning-roles list: an explicit null (reset to file) or
		// the new array — same sparse contract as the primitive rows.
		if (rolesCleared) setPath(PROVISION_ROLES_PATH, null);
		else if (rolesDirty) setPath(PROVISION_ROLES_PATH, provisionRoles);
		return patch;
	}

	const dirtyPaths = $derived.by(() => {
		const dirty: string[] = [];
		for (const path of ALL_PATHS) {
			const state = fields[path];
			if (!state) continue;
			if (SECRET_PATHS.includes(path as (typeof SECRET_PATHS)[number])) {
				// A pending clear or any typed text is dirty — typed plaintext
				// is saveable (Save stages it first); a staged handle is the
				// text and stays dirty. `staged && !text` is degenerate and
				// self-heals on reload.
				if (state.cleared || state.text !== '') dirty.push(path);
				continue;
			}
			if (state.cleared) {
				dirty.push(path);
				continue;
			}
			if (BOOL_PATHS.includes(path as (typeof BOOL_PATHS)[number])) {
				if (state.bool !== (data.values[path] === true)) dirty.push(path);
			} else if (NUMBER_PATHS.includes(path as (typeof NUMBER_PATHS)[number])) {
				if (state.text !== '' && Number.isFinite(Number(state.text))) {
					const original = data.values[path] == null ? null : Number(data.values[path]);
					if (Number(state.text) !== original) dirty.push(path);
				}
			} else {
				const original = data.values[path] == null ? '' : String(data.values[path]);
				if (state.text !== original) dirty.push(path);
			}
		}
		if (rolesDirty) dirty.push(PROVISION_ROLES_PATH);
		return dirty;
	});

	function resetField(path: string) {
		const state = fields[path];
		if (!state) return;
		state.cleared = true;
		state.staged = false;
		state.text = '';
		state.bool = false;
	}

	function undoClear(path: string) {
		const state = fields[path];
		if (!state) return;
		state.cleared = false;
		// Restore the displayed value from the effective snapshot.
		const value = data.values[path];
		state.text = value == null ? '' : String(value);
		state.bool = RETENTION_PATHS.includes(path)
			? value != null && Number(value) === 0
			: value === true;
	}

	/** Typing into a secret cancels a staged handle and a pending reset. */
	function secretTyped(path: string) {
		const state = fields[path];
		if (!state) return;
		state.staged = false;
		state.cleared = false;
	}

	// ── Keep-forever toggle (retention windows) ────────────────────
	//
	// A pinned `0` means "keep forever" — the backend pass skips. The
	// toggle owns that state: on → the field pins 0; off → the field
	// returns to what it was (the effective value, or an explicit null
	// through the reset-to-file flow when 0 was pinned). Typing a 0 flips
	// the toggle too, so the row never disagrees with itself. The bindable
	// `checked` has already flipped to the new value when `onchange` fires.

	function toggleKeepForever(path: string) {
		const state = fields[path];
		if (!state) return;
		if (state.bool) {
			// Checked → keep forever: pin 0 (cancels any pending reset).
			state.cleared = false;
			state.text = '0';
			return;
		}
		const original = data.values[path];
		if (isPinned(path) && original != null && Number(original) === 0) {
			// A pinned 0 returns to the file through the explicit-null reset.
			state.cleared = true;
			state.text = '';
		} else {
			// Restore the effective value — un-dirties a toggle that was
			// flipped on but not saved yet.
			state.text = original == null ? '' : String(original);
		}
	}

	function handleRetentionInput(path: string) {
		const state = fields[path];
		if (!state) return;
		// Typing a 0 *is* keep-forever — flip the toggle so the row agrees.
		if (state.text === '0') state.bool = true;
	}

	// ── Save-time secret staging ──────────────────────────────
	//
	// The plaintext lives only in `fields[path].text` while the admin types
	// it. Save is two-phase: phase 1 stages every typed plaintext and swaps
	// the single-use handle into the field state; phase 2 builds the sparse
	// patch (a staged field carries its handle) and hands it to the page.
	// The component never renders or logs the plaintext after the stage
	// call resolves. A stage failure renders inline on the row, aborts the
	// whole save (no PATCH runs), and keeps the plaintext in the input so
	// the admin can retry.

	let stagingNow: boolean = $state(false);
	let stageErrorPath: string | null = $state(null);
	let stageErrorMessage: string | null = $state(null);

	async function save() {
		stageErrorPath = null;
		stageErrorMessage = null;
		stagingNow = true;
		try {
			// Phase 1 — stage every typed secret plaintext. The first
			// failure aborts the whole save: the error renders on the row,
			// the plaintext stays for retry, and no PATCH runs.
			for (const path of SECRET_PATHS) {
				const state = fields[path];
				if (!state || state.staged || state.text === '') continue;
				try {
					const handle = await onStageSecret(path, state.text);
					state.text = handle;
					state.staged = true;
					state.cleared = false;
				} catch (e) {
					stageErrorPath = path;
					stageErrorMessage = e instanceof Error ? e.message : String(e);
					return;
				}
			}
		} finally {
			stagingNow = false;
		}
		// Phase 2 — the sparse patch; staged secrets carry their handles.
		await onSave(buildPatch());
	}

	// ── Test email ───────────────────────────────────────────
	//
	// One blocking delivery through the SAVED connector (the backend rebuilds
	// the adapter from the saved settings). The recipient defaults to the
	// signed-in account's address. A failure keeps the typed address so the
	// operator can fix and retry; the message is the transport's own words.
	// svelte-ignore state_referenced_locally — the recipient seeds a one-time
	// form session, like the `fields` bag above.
	let testRecipient: string = $state(defaultTestRecipient);
	let testing: boolean = $state(false);
	let testResult: { adapter: string; to: string } | null = $state(null);
	let testError: string | null = $state(null);

	// Unsaved mail edits make a test misleading: it runs the old connector.
	const mailDirty = $derived(dirtyPaths.some((path) => path.startsWith('mail.')));

	async function sendTest() {
		if (!onTestMail) return;
		testError = null;
		testResult = null;
		testing = true;
		try {
			const result = await onTestMail(testRecipient.trim());
			testResult = { adapter: result.adapter, to: result.to };
		} catch (e) {
			testError = e instanceof Error ? e.message : String(e);
		} finally {
			testing = false;
		}
	}

	// ── Test assistant ─────────────────────────────────────
	//
	// One blocking probe completion through the SAVED assistant settings —
	// the assistant counterpart of the mail test above. No input field: the
	// saved settings are the whole input. A `422` (no API key resolves) and
	// a `502` (provider or transport failure) both surface their message.
	let testingAssistant: boolean = $state(false);
	let assistantTestResult: { model: string; endpoint: string; reply: string | null } | null =
		$state(null);
	let assistantTestError: string | null = $state(null);

	// Unsaved assistant edits make a test misleading: it runs the old settings.
	const assistantDirty = $derived(dirtyPaths.some((path) => path.startsWith('assistant.')));

	async function sendAssistantTest() {
		if (!onTestAssistant) return;
		assistantTestError = null;
		assistantTestResult = null;
		testingAssistant = true;
		try {
			const result = await onTestAssistant();
			assistantTestResult = { model: result.model, endpoint: result.endpoint, reply: result.reply };
		} catch (e) {
			assistantTestError = e instanceof Error ? e.message : String(e);
		} finally {
			testingAssistant = false;
		}
	}

	// ── Group layout ───────────────────────────────────────────────────
	// The row descriptors use the `FieldRow` type from SettingsFieldRow;
	// the `adapter` row carries its option list in `options`.

	const ASSISTANT_FIELDS: FieldRow[] = [
		{
			path: 'assistant.name',
			label: m.system_settings_assistant_name(),
			kind: 'string',
			helper: m.system_settings_assistant_name_helper()
		},
		{
			path: 'assistant.api_endpoint',
			label: m.system_settings_assistant_endpoint(),
			kind: 'string',
			helper: m.system_settings_assistant_endpoint_helper()
		},
		{
			path: 'assistant.api_key',
			label: m.system_settings_assistant_api_key(),
			kind: 'secret',
			helper: m.system_settings_assistant_api_key_helper()
		},
		{
			path: 'assistant.model',
			label: m.system_settings_assistant_model(),
			kind: 'string',
			helper: m.system_settings_assistant_model_helper()
		},
		{
			path: 'assistant.temperature',
			label: m.system_settings_assistant_temperature(),
			kind: 'number',
			helper: m.system_settings_assistant_temperature_helper()
		},
		{
			path: 'assistant.system_prompt',
			label: m.system_settings_assistant_prompt(),
			kind: 'text',
			helper: m.system_settings_assistant_prompt_helper(),
			wide: true
		},
		{
			path: 'assistant.max_tokens',
			label: m.system_settings_assistant_max_tokens(),
			kind: 'number',
			helper: m.system_settings_assistant_max_tokens_helper()
		},
		{
			path: 'assistant.max_history',
			label: m.system_settings_assistant_max_history(),
			kind: 'number',
			helper: m.system_settings_assistant_max_history_helper()
		},
		{
			path: 'assistant.auto_execute_tools',
			label: m.system_settings_assistant_auto_tools(),
			kind: 'bool',
			helper: m.system_settings_assistant_auto_tools_helper(),
			wide: true
		}
	];

	const adapterOptions = [
		{ value: 'dev', label: m.system_settings_adapter_dev() },
		{ value: 'smtp', label: m.system_settings_adapter_smtp() }
	];

	const MAIL_FIELDS: FieldRow[] = [
		{
			path: 'mail.adapter',
			label: m.system_settings_mail_adapter(),
			kind: 'adapter',
			helper: m.system_settings_mail_adapter_helper(),
			options: adapterOptions,
			wide: true
		},
		{
			path: 'mail.from_address',
			label: m.system_settings_mail_from_address(),
			kind: 'string',
			helper: m.system_settings_mail_from_address_helper()
		},
		{
			path: 'mail.from_name',
			label: m.system_settings_mail_from_name(),
			kind: 'string',
			helper: m.system_settings_mail_from_name_helper()
		}
	];

	const SMTP_FIELDS: FieldRow[] = [
		{
			path: 'mail.smtp.host',
			label: m.system_settings_mail_smtp_host(),
			kind: 'string',
			helper: m.system_settings_mail_smtp_host_helper()
		},
		{
			path: 'mail.smtp.port',
			label: m.system_settings_mail_smtp_port(),
			kind: 'number',
			helper: m.system_settings_mail_smtp_port_helper()
		},
		{
			path: 'mail.smtp.username',
			label: m.system_settings_mail_smtp_username(),
			kind: 'string',
			helper: m.system_settings_mail_smtp_username_helper()
		},
		{
			path: 'mail.smtp.password',
			label: m.system_settings_mail_smtp_password(),
			kind: 'secret',
			helper: m.system_settings_mail_smtp_password_helper()
		},
		{
			path: 'mail.smtp.use_tls',
			label: m.system_settings_mail_smtp_tls(),
			kind: 'bool',
			helper: m.system_settings_mail_smtp_tls_helper(),
			wide: true
		}
	];

	const ARTIFACT_FIELDS: FieldRow[] = [
		{
			path: 'artifact.grant_ttl_seconds',
			label: m.system_settings_artifact_grant_ttl(),
			kind: 'number',
			helper: m.system_settings_artifact_grant_ttl_helper()
		},
		{
			path: 'artifact.grant_ttl_media_seconds',
			label: m.system_settings_artifact_grant_ttl_media(),
			kind: 'number',
			helper: m.system_settings_artifact_grant_ttl_media_helper()
		},
		{
			path: 'artifact.prune_after_days',
			label: m.system_settings_artifact_prune(),
			kind: 'retention',
			helper: m.system_settings_artifact_prune_helper()
		}
	];

	const RETENTION_FIELDS: FieldRow[] = [
		{
			path: 'mutations.retention_days',
			label: m.system_settings_retention_mutations(),
			kind: 'retention',
			helper: m.system_settings_retention_mutations_helper()
		},
		{
			path: 'tombstone.content_retention_days',
			label: m.system_settings_retention_tombstones(),
			kind: 'retention',
			helper: m.system_settings_retention_tombstones_helper()
		}
	];

	// ── Localization chapter — the instance defaults an account follows
	// until it picks its own values. The zone list is the shared builder
	// (lib/timezones.ts), the same one the personal settings page renders.
	// `auto` leads the zone options: it is the built-in default (follow each
	// account's browser) and the value a stock install resolves to.
	const LOCALIZATION_FIELDS: FieldRow[] = [
		{
			path: 'localization.default_timezone',
			label: m.system_settings_localization_timezone(),
			kind: 'enum',
			helper: m.system_settings_localization_timezone_helper(),
			options: [
				{ value: 'auto', label: m.system_settings_localization_timezone_auto() },
				{ value: 'UTC', label: 'UTC' },
				...allTimezones()
					.filter((zone) => zone !== 'UTC')
					.map((zone) => ({ value: zone, label: zone }))
			]
		},
		{
			path: 'localization.default_language',
			label: m.system_settings_localization_language(),
			kind: 'enum',
			helper: m.system_settings_localization_language_helper(),
			options: [
				{ value: 'en', label: m.language_name_en() },
				{ value: 'fr', label: m.language_name_fr() }
			]
		}
	];

	// ── Security chapter — the IAM policy. The enums follow the write
	// gate's grammars; the enforcement select renders only while the
	// pending factor type is 'totp' (a control that does nothing is a
	// control that lies). The credential-link TTL is a plain number
	// field — seconds, minimum 1 (the write gate refuses lower values);
	// no keep-forever tier.
	const SECURITY_FIELDS: FieldRow[] = [
		{
			path: 'iam.mfa.type',
			label: m.system_settings_mfa_type(),
			kind: 'enum',
			helper: m.system_settings_mfa_type_helper(),
			options: [
				{ value: 'none', label: m.system_settings_mfa_type_none() },
				{ value: 'totp', label: m.system_settings_mfa_type_totp() }
			]
		},
		{
			path: 'iam.mfa.enforcement',
			label: m.system_settings_mfa_enforcement(),
			kind: 'enum',
			helper: m.system_settings_mfa_enforcement_helper(),
			options: [
				{ value: 'preferred', label: m.system_settings_mfa_enforcement_preferred() },
				{ value: 'always', label: m.system_settings_mfa_enforcement_always() }
			]
		},
		{
			path: 'iam.auth.mode',
			label: m.system_settings_auth_mode(),
			kind: 'enum',
			helper: m.system_settings_auth_mode_helper(),
			options: [
				{ value: 'hybrid', label: m.system_settings_auth_mode_hybrid() },
				{ value: 'oidc_only', label: m.system_settings_auth_mode_oidc_only() }
			]
		},
		{
			path: 'iam.change_password_expiration',
			label: m.system_settings_credential_link_ttl(),
			kind: 'number',
			helper: m.system_settings_credential_link_ttl_helper()
		}
	];

	// The SMTP transport block renders only while the live adapter value is
	// 'smtp' — the select binds the form state, so the block follows the
	// pending selection, not the saved snapshot. An unset value hides it.
	const smtpVisible = $derived(fields['mail.adapter']?.text === 'smtp');

	// The pending factor type drives the enforcement select's visibility
	// (the SMTP-block pattern): a select that does nothing under 'none'
	// is a control that lies.
	const enforcementVisible = $derived(fields['iam.mfa.type']?.text !== 'none');

	// The storage adapter is registered read-only: the value comes from the
	// config file at boot and never enters the patch. An unset value (older
	// snapshot) renders the raw empty string rather than a guess.
	const adapterValue = $derived(String(data.values['artifact.storage.type'] ?? ''));
	const adapterLabel = $derived(
		adapterValue === 's3'
			? m.system_settings_artifact_adapter_s3()
			: adapterValue === 'filesystem'
				? m.system_settings_artifact_adapter_filesystem()
				: adapterValue
	);

	// ── Chapter navigation ────────────────────────────────────────────
	//
	// A sticky rail links to each group; the active chapter follows the
	// scroll position. The spy and the smooth scroll live in the shared
	// `createChapterScroll` helper (primitives/surfaces) — the same
	// mechanism the personal settings page uses.

	const chapters: Chapter[] = [
		{ id: 'assistant', label: m.system_settings_group_assistant(), icon: Bot },
		{ id: 'mail', label: m.system_settings_group_mail(), icon: Mail },
		{ id: 'localization', label: m.system_settings_group_localization(), icon: Globe },
		{ id: 'security', label: m.system_settings_group_security(), icon: KeyRound },
		{ id: 'artifacts', label: m.system_settings_group_artifacts(), icon: Package },
		{ id: 'retention', label: m.system_settings_group_retention(), icon: History }
	];

	let rootEl: HTMLElement | undefined = $state();

	const chapterScroll = createChapterScroll({
		ids: () => chapters.map((chapter) => chapter.id),
		prefix: 'settings-chapter'
	});

	$effect(() => {
		const el = rootEl;
		if (!el) return;
		return chapterScroll.watch(el);
	});
</script>

<div class="settings-shell" bind:this={rootEl}>
	<ChapterNav
		{chapters}
		activeId={chapterScroll.active}
		onNavigate={chapterScroll.scrollTo}
		label={m.system_settings_nav_aria()}
	/>

	<div class="chapter-content">
		<section id="settings-chapter-assistant" class="group" aria-labelledby="assistant-heading">
			<div class="group-head">
				<h2 id="assistant-heading" class="group-heading">
					<Bot size={14} stroke-width={1.9} aria-hidden="true" />
					{m.system_settings_group_assistant()}
				</h2>
				<p class="group-note">{m.system_settings_group_assistant_note()}</p>
			</div>

			<div class="group-grid">
				{#each ASSISTANT_FIELDS as row (row.path)}
					{@render fieldRow(row)}
				{/each}

				{#if onTestAssistant}
					<div class="assistant-test" data-testid="assistant-test">
						<h3 class="sub-heading">{m.system_settings_assistant_test_heading()}</h3>
						<p class="sub-note">{m.system_settings_assistant_test_note()}</p>

						<div class="assistant-test-controls">
							<Button
								variant="secondary"
								label={testingAssistant
									? m.system_settings_assistant_test_sending()
									: m.system_settings_assistant_test_send()}
								loading={testingAssistant}
								disabled={testingAssistant}
								onclick={() => void sendAssistantTest()}
							/>
						</div>

						{#if assistantDirty}
							<p class="mail-test-note mail-test-warn" role="status">
								{m.system_settings_assistant_test_unsaved()}
							</p>
						{:else if assistantTestResult}
							<p class="mail-test-note mail-test-ok" role="status">
								{assistantTestResult.reply
									? m.system_settings_assistant_test_sent({
											model: assistantTestResult.model,
											reply: assistantTestResult.reply
										})
									: m.system_settings_assistant_test_ok({
											model: assistantTestResult.model,
											endpoint: assistantTestResult.endpoint
										})}
							</p>
						{:else if assistantTestError}
							<p class="mail-test-note mail-test-error" role="alert">
								{m.system_settings_assistant_test_failed({ message: assistantTestError })}
							</p>
						{/if}
					</div>
				{/if}
			</div>
		</section>

		<section id="settings-chapter-mail" class="group" aria-labelledby="mail-heading">
			<div class="group-head">
				<h2 id="mail-heading" class="group-heading">
					<Mail size={14} stroke-width={1.9} aria-hidden="true" />
					{m.system_settings_group_mail()}
				</h2>
				<p class="group-note">{m.system_settings_group_mail_note()}</p>
			</div>

			<div class="group-grid">
				{#each MAIL_FIELDS as row (row.path)}
					{@render fieldRow(row)}
				{/each}

				{#if smtpVisible}
					<h3 class="sub-heading">{m.system_settings_mail_smtp_heading()}</h3>
					<p class="sub-note">{m.system_settings_mail_smtp_heading_note()}</p>

					{#each SMTP_FIELDS as row (row.path)}
						{@render fieldRow(row)}
					{/each}
				{/if}

				{#if onTestMail}
					<div class="mail-test" data-testid="mail-test">
						<h3 class="sub-heading">{m.system_settings_mail_test_heading()}</h3>
						<p class="sub-note">{m.system_settings_mail_test_note()}</p>

						<div class="mail-test-controls">
							<Input
								type="email"
								label={m.system_settings_mail_test_recipient()}
								helper={m.system_settings_mail_test_recipient_helper()}
								bind:value={testRecipient}
								disabled={testing}
							/>
							<Button
								variant="secondary"
								label={testing
									? m.system_settings_mail_test_sending()
									: m.system_settings_mail_test_send()}
								loading={testing}
								disabled={testing || testRecipient.trim() === ''}
								onclick={() => void sendTest()}
							/>
						</div>

						{#if mailDirty}
							<p class="mail-test-note mail-test-warn" role="status">
								{m.system_settings_mail_test_unsaved()}
							</p>
						{:else if testResult}
							<p class="mail-test-note mail-test-ok" role="status">
								{m.system_settings_mail_test_sent({
									adapter: testResult.adapter,
									to: testResult.to
								})}
							</p>
						{:else if testError}
							<p class="mail-test-note mail-test-error" role="alert">
								{m.system_settings_mail_test_failed({ message: testError })}
							</p>
						{/if}
					</div>
				{/if}
			</div>
		</section>

		<section
			id="settings-chapter-localization"
			class="group"
			aria-labelledby="localization-heading"
		>
			<div class="group-head">
				<h2 id="localization-heading" class="group-heading">
					<Globe size={14} stroke-width={1.9} aria-hidden="true" />
					{m.system_settings_group_localization()}
				</h2>
				<p class="group-note">{m.system_settings_group_localization_note()}</p>
			</div>

			<div class="group-grid">
				{#each LOCALIZATION_FIELDS as row (row.path)}
					{@render fieldRow(row)}
				{/each}
			</div>
		</section>

		<section id="settings-chapter-security" class="group" aria-labelledby="security-heading">
			<div class="group-head">
				<h2 id="security-heading" class="group-heading">
					<KeyRound size={14} stroke-width={1.9} aria-hidden="true" />
					{m.system_settings_group_security()}
				</h2>
				<p class="group-note">{m.system_settings_group_security_note()}</p>
			</div>

			<div class="group-grid">
				{#each SECURITY_FIELDS as row (row.path)}
					{#if row.path !== 'iam.mfa.enforcement' || enforcementVisible}
						{@render fieldRow(row)}
					{/if}
				{/each}

				<div
					class="field-row wide"
					data-path={PROVISION_ROLES_PATH}
					data-pinned={isPinned(PROVISION_ROLES_PATH)}
				>
					<div class="roles-head">
						<span class="field-label">{m.system_settings_provision_roles()}</span>
						{#if rolesCleared}
							<div class="field-status">
								<Badge label={m.system_settings_reset_pending()} variant="warn" size="sm" />
								<button class="undo-btn" type="button" onclick={undoRolesClear}>
									{m.system_settings_undo()}
								</button>
							</div>
						{:else if isPinned(PROVISION_ROLES_PATH)}
							<div class="field-status">
								<Badge label={m.system_settings_override_badge()} variant="accent" size="sm" />
								<button
									class="undo-btn"
									type="button"
									title={m.system_settings_reset_title()}
									onclick={resetProvisionRoles}
								>
									<RotateCcw size={13} aria-hidden="true" />
									{m.system_settings_reset_to_file()}
								</button>
							</div>
						{/if}
					</div>
					<p class="field-helper">{m.system_settings_provision_roles_helper()}</p>

					{#if provisionRoles.length === 0 && !rolesCleared}
						<p class="roles-empty">{m.system_settings_provision_roles_empty()}</p>
					{:else if provisionRoles.length > 0}
						<ul class="roles-list">
							{#each provisionRoles as role (role)}
								<li class="role-capsule">
									<span class="role-name">{role}</span>
									<button
										class="role-remove"
										type="button"
										aria-label={m.system_settings_provision_roles_remove()}
										onclick={() => removeProvisionRole(role)}
									>
										<X size={12} aria-hidden="true" />
									</button>
								</li>
							{/each}
						</ul>
					{/if}

					{#if driver}
						<ReferencePicker
							label={m.system_settings_provision_roles_add()}
							helper={m.system_settings_provision_roles_add_helper()}
							doctype="iam.Roles"
							{driver}
							bind:value={addRoleValue}
						/>
					{/if}
				</div>

				<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- /Configure/platform/oidc is a sibling page on the same shell, reached through the Caddy proxy; the resolve() helper is not imported here and the rule cannot see the shell layout. -->
				<a class="oidc-link" href="/Configure/platform/oidc">
					{m.system_settings_security_oidc_link()}
				</a>
			</div>
		</section>

		<section id="settings-chapter-artifacts" class="group" aria-labelledby="artifacts-heading">
			<div class="group-head">
				<h2 id="artifacts-heading" class="group-heading">
					<Package size={14} stroke-width={1.9} aria-hidden="true" />
					{m.system_settings_group_artifacts()}
				</h2>
				<p class="group-note">{m.system_settings_group_artifacts_note()}</p>
			</div>

			<div class="group-grid">
				<div class="field-row wide" data-path="artifact.storage.type" data-readonly="true">
					<div class="readonly-line">
						<span class="field-label">{m.system_settings_artifact_adapter()}</span>
						<span class="readonly-value">{adapterLabel}</span>
					</div>
					<p class="field-helper">{m.system_settings_artifact_adapter_helper()}</p>
				</div>

				{#each ARTIFACT_FIELDS as row (row.path)}
					{@render fieldRow(row)}
				{/each}
			</div>
		</section>

		<section id="settings-chapter-retention" class="group" aria-labelledby="retention-heading">
			<div class="group-head">
				<h2 id="retention-heading" class="group-heading">
					<History size={14} stroke-width={1.9} aria-hidden="true" />
					{m.system_settings_group_retention()}
				</h2>
				<p class="group-note">{m.system_settings_group_retention_note()}</p>
			</div>

			<div class="group-grid">
				{#each RETENTION_FIELDS as row (row.path)}
					{@render fieldRow(row)}
				{/each}
			</div>
		</section>

		<div class="save-row">
			<span class="dirty-note">
				{dirtyPaths.length === 0
					? m.system_settings_no_changes()
					: m.system_settings_dirty_count({ 0: dirtyPaths.length })}
			</span>
			<Button
				label={saving || stagingNow ? m.common_loading() : m.common_save()}
				disabled={saving || stagingNow || dirtyPaths.length === 0}
				onclick={() => void save()}
			/>
		</div>
	</div>
</div>

{#snippet fieldRow(row: FieldRow)}
	<SettingsFieldRow
		{row}
		bind:text={fields[row.path].text}
		bind:bool={fields[row.path].bool}
		cleared={fields[row.path].cleared}
		staged={fields[row.path].staged}
		pinned={isPinned(row.path)}
		stageError={stageErrorPath === row.path ? stageErrorMessage : null}
		onSecretInput={() => secretTyped(row.path)}
		onRetentionInput={() => handleRetentionInput(row.path)}
		onKeepForever={() => toggleKeepForever(row.path)}
		onReset={() => resetField(row.path)}
		onUndoClear={() => undoClear(row.path)}
	/>
{/snippet}

<style>
	/* ── Shell — sticky chapter rail + content column ─────────────── */

	.settings-shell {
		display: grid;
		grid-template-columns: 190px minmax(0, 1fr);
		gap: 28px;
		align-items: start;
	}

	.chapter-content {
		display: flex;
		flex-direction: column;
		gap: 20px;
		min-width: 0;
	}

	/* ── Group cards ──────────────────────────────────────────── */

	.group {
		display: flex;
		flex-direction: column;
		gap: 16px;
		padding: 20px;
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		background: var(--surface);
		scroll-margin-top: 20px;
	}

	.group-head {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.group-heading {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		margin: 0;
		font-size: 12px;
		font-weight: 700;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-2);
	}

	.group-heading :global(svg) {
		color: var(--text-3);
	}

	.group-note {
		margin: 0;
		font-size: 12px;
		color: var(--text-3);
	}

	/* ── Field grid — two columns, wide rows span both ────────────────── */

	.group-grid {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 14px 20px;
		align-items: start;
	}

	/* The read-only adapter row is raw markup and renders outside
	   SettingsFieldRow, so it keeps the row chrome here. */
	.field-row {
		display: flex;
		flex-direction: column;
		gap: 5px;
		min-width: 0;
	}

	.field-row.wide {
		grid-column: 1 / -1;
	}

	.sub-heading {
		grid-column: 1 / -1;
		margin: 8px 0 -4px;
		padding-top: 12px;
		border-top: 1px solid var(--border);
		font-size: 11px;
		font-weight: 700;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.sub-note {
		grid-column: 1 / -1;
		margin: -8px 0 0;
		font-size: 11.5px;
		color: var(--text-3);
	}

	/* ── Test email — recipient + send, with the outcome underneath ── */

	.mail-test,
	.assistant-test {
		display: flex;
		flex-direction: column;
		gap: 8px;
		grid-column: 1 / -1;
		padding-top: 12px;
		border-top: 1px solid var(--border);
	}

	.mail-test .sub-heading,
	.assistant-test .sub-heading {
		border-top: none;
		padding-top: 0;
		margin: 0;
	}

	.mail-test-controls {
		display: flex;
		align-items: flex-start;
		gap: 12px;
	}

	.mail-test-controls :global(:first-child) {
		flex: 1;
		min-width: 0;
	}

	.mail-test-controls :global(button) {
		margin-top: 22px;
		white-space: nowrap;
	}

	.mail-test-note,
	.assistant-test .mail-test-note {
		margin: 0;
		font-size: 11.5px;
		line-height: 1.45;
	}

	.mail-test-ok {
		color: var(--text-2);
	}

	.mail-test-warn {
		color: var(--warn);
	}

	.mail-test-error {
		color: var(--danger);
	}

	/* ── Shared field chrome (matches Field.svelte) ───────────────── */
	/* The read-only adapter row renders these directly; the field rows
	   render them through SettingsFieldRow. */

	.field-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	/* ── Provisioning roles ─────────────────────────────────── */

	.roles-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
		flex-wrap: wrap;
	}

	.roles-empty {
		margin: 0;
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
	}

	.roles-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
	}

	.role-capsule {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 4px 6px 4px 10px;
		border: 1px solid var(--border);
		border-radius: 999px;
		background: var(--surface);
		font-size: 12px;
		color: var(--text);
	}

	.role-remove {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 18px;
		height: 18px;
		padding: 0;
		border: none;
		border-radius: 50%;
		background: var(--sunken);
		color: var(--text-2);
		cursor: pointer;
	}

	.role-remove:hover {
		background: var(--danger-weak);
		color: var(--danger);
	}

	/* The status cluster mirrors SettingsFieldRow's reset/undo controls. */
	.field-status {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.undo-btn {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 4px 8px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text-2);
		font-size: 11.5px;
		cursor: pointer;
		white-space: nowrap;
	}

	.undo-btn:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.field-helper {
		margin: 0;
		font-size: 11.5px;
		line-height: 1.45;
		color: var(--text-3);
	}

	/* ── Read-only field (storage adapter) ───────────────── */

	.readonly-line {
		display: flex;
		align-items: center;
		gap: 10px;
		min-height: 34px;
	}

	.readonly-value {
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		padding: 5px 10px;
	}

	/* ── Save row ─────────────────────────────────────────── */

	.save-row {
		display: flex;
		align-items: center;
		justify-content: flex-end;
		gap: 12px;
		position: sticky;
		bottom: 0;
		padding: 12px 0;
		background: linear-gradient(to top, var(--ground) 70%, transparent);
	}

	.dirty-note {
		font-size: 12px;
		color: var(--text-3);
	}

	.oidc-link {
		grid-column: 1 / -1;
		font-size: 12.5px;
		color: var(--accent-ink);
		text-decoration: none;
	}

	.oidc-link:hover {
		opacity: 0.7;
	}

	/* ── Narrow viewports collapse to one column ───────────────────────── */
	/* ── Narrow viewports ────────────────────────────────── */

	@media (max-width: 900px) {
		.settings-shell {
			grid-template-columns: 1fr;
			gap: 16px;
		}
	}

	@media (max-width: 760px) {
		.group-grid {
			grid-template-columns: 1fr;
		}

		.field-row.wide {
			grid-column: auto;
		}

		.mail-test-controls {
			flex-direction: column;
			align-items: stretch;
		}

		.mail-test-controls :global(button) {
			margin-top: 0;
		}
	}
</style>

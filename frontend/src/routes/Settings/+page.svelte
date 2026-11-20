<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import type { SelectOption } from '$lib/components/primitives/forms/Select.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import ChapterNav from '$lib/components/primitives/surfaces/ChapterNav.svelte';
	import type { Chapter } from '$lib/components/primitives/surfaces/ChapterNav.svelte';
	import { createChapterScroll } from '$lib/components/primitives/surfaces/chapterScroll.svelte.js';
	import McpEndpoints from '$lib/components/features/settings/McpEndpoints.svelte';
	import Sessions from '$lib/components/features/settings/Sessions.svelte';
	import { Bell, Globe, MonitorSmartphone, Plug, Sparkles, User } from '@lucide/svelte';
	import {
		loadSettings,
		saveTimezone,
		saveLanguage,
		saveShowWelcome,
		clearSetting,
		getDefaults,
		getTimezone,
		getLanguage,
		reconcileLocale,
		systemTimezone,
		AUTO_TIMEZONE
	} from '$lib/settings.svelte';
	import { allTimezones, zoneOffsetLabel } from '$lib/timezones.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { createSaveFlash } from '$lib/utils/saveFlash.svelte.js';
	import { ensureNotificationsPreference, setInAppEnabled } from '$lib/notifications.svelte';
	import { getActiveRole } from '$lib/role.svelte';
	import * as m from '$lib/paraglide/messages';
	import { getLocale } from '$lib/paraglide/runtime';

	/**
	 * Personal settings (/Settings).
	 *
	 * The chaptered layout of the platform settings page: a sticky chapter
	 * rail on the left and one column of full-width groups on the right —
	 * General, Notifications, the admin-only Welcome tour, the MCP
	 * endpoints, and the active sessions. Every group owns its chrome
	 * (icon, heading, note) here; McpEndpoints and Sessions render their
	 * bodies only. Saves are per-field and instant — each control flashes
	 * its own saved/error state, so there is no global save row.
	 */

	let { data } = $props();

	/** All IANA zones the runtime supports — the shared list (see `lib/timezones.ts`). */
	const allZones: string[] = allTimezones();

	// `page.data.account` is the authenticated profile; `data` is unused by this page.

	// ── Persisted preferences (loaded from the backend) ─────────────────────
	// The frontend-only sentinel for the "Server default" option: selecting
	// it deletes the account's row (the DELETE route) so the server policy
	// applies again. It is never sent to the backend as a value.
	const SERVER_DEFAULT = 'server-default';

	let timezone = $state(AUTO_TIMEZONE);
	let language = $state('en');
	let loadError = $state<string | undefined>(undefined);

	/** The server-effective defaults, read from the store after load. */
	const defaults = $derived(getDefaults());

	/** The merged value the store holds for one key (server default applied). */
	function loadSettingValue(key: 'timezone' | 'language'): string {
		return key === 'timezone' ? (getTimezone() ?? AUTO_TIMEZONE) : (getLanguage() ?? 'en');
	}

	// ── Per-field save feedback ─────────────────────────────────────────────
	const timezoneFlash = createSaveFlash(2000);
	const languageFlash = createSaveFlash(2000);

	// ── Notifications — persisted via the notifications settings scope ──────
	let inApp = $state(false);
	let inAppLoaded = $state(false);
	const notifFlash = createSaveFlash(2000);

	// ── Welcome tour — the core.show_welcome flag (admin-only section) ──────
	let welcomeEnabled = $state(true);
	let welcomeLoaded = $state(false);
	const welcomeFlash = createSaveFlash(2000);

	// The tour section renders only for the seeded admin role (D3): a
	// non-admin gets no popup and no toggle — the flag sits inert on their row.
	const isAdmin = $derived((getActiveRole() ?? data.activeRole) === 'iam.Roles.admin');

	// Load persisted preferences once on mount.
	$effect(() => {
		loadSettings()
			.then((values) => {
				timezone = values.timezone;
				language = values.language;
				welcomeEnabled = values.showWelcome;
				welcomeLoaded = true;
			})
			.catch((e: unknown) => {
				loadError = errorMessage(e, m.settings_load_fallback());
			});
	});

	// The notifications preference lives in its own settings scope; the
	// notifications store owns the read (`loadPreference` fails open, so the
	// toggle shows the registered default when the scope is unreachable).
	$effect(() => {
		void ensureNotificationsPreference().then((enabled) => {
			inApp = enabled;
			inAppLoaded = true;
		});
	});

	async function handleTimezoneChange(value: string) {
		timezoneFlash.saving();
		try {
			if (value === SERVER_DEFAULT) {
				// Follow the server policy again: delete the row and reload.
				await clearSetting('timezone');
				timezone = loadSettingValue('timezone');
				timezoneFlash.saved();
				return;
			}
			// Resolve the auto sentinel to the concrete system zone before saving.
			await saveTimezone(value === AUTO_TIMEZONE ? systemTimezone() : value);
			timezone = value;
			timezoneFlash.saved();
		} catch (e) {
			timezoneFlash.failed(errorMessage(e, m.settings_timezone_save_error()));
		}
	}

	async function handleLanguageChange(value: string) {
		languageFlash.saving();
		try {
			if (value === SERVER_DEFAULT) {
				// clearSetting reloads the store, which also re-syncs the Paraglide
				// locale with the server-default language.
				await clearSetting('language');
				language = loadSettingValue('language');
				languageFlash.saved();
				return;
			}
			await saveLanguage(value);
			language = value;
			languageFlash.saved();
			// Sync the Paraglide cookie and reload so SSR-rendered strings and
			// Intl-formatted names switch with the stored preference.
			reconcileLocale(value);
		} catch (e) {
			languageFlash.failed(errorMessage(e, m.settings_language_save_error()));
		}
	}

	async function handleNotificationsChange() {
		notifFlash.saving();
		// The bindable `checked` already flipped to the new value when
		// `onchange` fires; revert it if the backend refuses the write.
		const next = inApp;
		try {
			await setInAppEnabled(next);
			notifFlash.saved();
		} catch (e) {
			inApp = !next;
			notifFlash.failed(errorMessage(e, m.settings_notifications_save_error()));
		}
	}

	async function handleWelcomeChange() {
		welcomeFlash.saving();
		// The bindable `checked` already flipped to the new value when
		// `onchange` fires; revert it if the backend refuses the write.
		const next = welcomeEnabled;
		try {
			await saveShowWelcome(next);
			welcomeFlash.saved();
		} catch (e) {
			welcomeEnabled = !next;
			welcomeFlash.failed(errorMessage(e, m.welcome_save_error()));
		}
	}

	/** Build grouped timezone options, one section per continent. */
	const timezoneOptions = $derived.by(() => {
		const groups: Record<string, { value: string; label: string }[]> = {};
		for (const zone of allZones) {
			// UTC has no continent and no city: the offset-label template
			// degrades for it. It renders as a flat featured option below.
			if (zone === 'UTC') continue;
			const parts = zone.split('/');
			const continent = parts[0];
			const city = parts.slice(1).join(' / ');
			if (!groups[continent]) groups[continent] = [];
			groups[continent].push({
				value: zone,
				label: m.settings_timezone_offset_label({ offset: zoneOffsetLabel(zone), city })
			});
		}
		const continents = Object.keys(groups).sort();
		const out: SelectOption[] = [
			{
				value: AUTO_TIMEZONE,
				label: m.settings_timezone_auto_label({ zone: systemTimezone() }),
				featured: true,
				icon: Globe
			}
		];
		out.push({
			value: SERVER_DEFAULT,
			label: m.settings_server_default({ value: defaults?.timezone ?? 'UTC' }),
			featured: true
		});
		// The merged value can be 'UTC' (the server default on a stock
		// install). A plain UTC option guarantees the picker holds an option
		// for the bound value — the same entry the platform SystemSettingsForm
		// pins first. Without it, no option matches and the stale label acts
		// as a search query on open.
		out.push({ value: 'UTC', label: 'UTC', featured: true });
		for (const continent of continents) {
			groups[continent].sort((a, b) => a.label.localeCompare(b.label));
			out.push({ group: continent, options: groups[continent] });
		}
		return out;
	});

	// The language select: the interface languages the build ships, plus the
	// server-default option first. The list mirrors the backend
	// ALLOWED_LANGUAGES registry.
	const languageOptions = $derived.by(() => {
		const out: { value: string; label: string }[] = [
			{
				value: SERVER_DEFAULT,
				label: m.settings_server_default({ value: defaults?.language ?? 'en' })
			}
		];
		out.push({ value: 'en', label: 'English' });
		out.push({ value: 'fr', label: 'Français' });
		return out;
	});

	const shownTimezone = $derived(timezone === AUTO_TIMEZONE ? systemTimezone() : timezone);

	// ── Chapter navigation ──────────────────────────────────────────────────
	// The rail mirrors the groups below; the Welcome chapter exists only for
	// the admin role, so the list derives from `isAdmin`. The spy and the
	// smooth scroll live in the shared `createChapterScroll` helper (same
	// mechanism as the platform settings form).

	const chapters = $derived.by<Chapter[]>(() => {
		const list: Chapter[] = [
			{ id: 'general', label: m.settings_general_title(), icon: User },
			{ id: 'notifications', label: m.settings_notifications_title(), icon: Bell }
		];
		if (isAdmin) list.push({ id: 'welcome', label: m.settings_welcome_title(), icon: Sparkles });
		list.push(
			{ id: 'mcp', label: m.mcp_title(), icon: Plug },
			{ id: 'sessions', label: m.sessions_title(), icon: MonitorSmartphone }
		);
		return list;
	});

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

<svelte:head>
	<title>{m.settings_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader title={m.settings_title()} subtitle={m.settings_subtitle()} />

	{#if loadError}
		<p class="load-error" role="alert">{m.settings_load_error({ message: loadError })}</p>
	{/if}

	<div class="settings-shell" bind:this={rootEl}>
		<ChapterNav
			{chapters}
			activeId={chapterScroll.active}
			onNavigate={chapterScroll.scrollTo}
			label={m.system_settings_nav_aria()}
		/>

		<div class="chapter-content">
			<section id="settings-chapter-general" class="group" aria-labelledby="general-heading">
				<div class="group-head">
					<h2 id="general-heading" class="group-heading">
						<User size={14} stroke-width={1.9} aria-hidden="true" />
						{m.settings_general_title()}
					</h2>
					<p class="group-note">{m.settings_general_helper()}</p>
				</div>

				<div class="group-grid">
					<div class="field-row">
						<div class="field-main">
							<Select
								label={m.settings_timezone_label()}
								options={timezoneOptions}
								bind:value={timezone}
								onValueChange={handleTimezoneChange}
								helper={m.settings_timezone_helper()}
							/>
							{#if timezoneFlash.message}
								<p class="field-error" role="alert">{timezoneFlash.message}</p>
							{/if}
						</div>
						<span class="field-status" class:show={timezoneFlash.status === 'saved'}
							>{m.common_saved()}</span
						>
					</div>

					<div class="field-row">
						<div class="field-main">
							<Select
								label={m.settings_language_label()}
								options={languageOptions}
								bind:value={language}
								onValueChange={handleLanguageChange}
								helper={m.settings_language_helper()}
							/>
							{#if languageFlash.message}
								<p class="field-error" role="alert">{languageFlash.message}</p>
							{/if}
						</div>
						<span class="field-status" class:show={languageFlash.status === 'saved'}
							>{m.common_saved()}</span
						>
					</div>

					<div class="tz-preview">
						<span class="tz-preview-label">{m.settings_timezone_current_label()}</span>
						<time class="tz-preview-time"
							>{new Date().toLocaleString(getLocale(), { timeZone: shownTimezone })}</time
						>
					</div>
				</div>
			</section>

			<section
				id="settings-chapter-notifications"
				class="group"
				aria-labelledby="notifications-heading"
			>
				<div class="group-head">
					<h2 id="notifications-heading" class="group-heading">
						<Bell size={14} stroke-width={1.9} aria-hidden="true" />
						{m.settings_notifications_title()}
					</h2>
					<p class="group-note">{m.settings_notifications_helper()}</p>
				</div>

				<div class="toggle-row">
					{#if inAppLoaded}
						<div class="toggle-line">
							<Toggle
								label={m.settings_notifications_inapp_label()}
								bind:checked={inApp}
								onchange={handleNotificationsChange}
							/>
							<span class="field-status toggle-status" class:show={notifFlash.status === 'saved'}
								>{m.common_saved()}</span
							>
						</div>
					{/if}
					<p class="toggle-desc">{m.settings_notifications_inapp_helper()}</p>
					{#if notifFlash.message}
						<p class="field-error" role="alert">{notifFlash.message}</p>
					{/if}
				</div>
			</section>

			{#if isAdmin}
				<section id="settings-chapter-welcome" class="group" aria-labelledby="welcome-heading">
					<div class="group-head">
						<h2 id="welcome-heading" class="group-heading">
							<Sparkles size={14} stroke-width={1.9} aria-hidden="true" />
							{m.settings_welcome_title()}
						</h2>
						<p class="group-note">{m.settings_welcome_helper()}</p>
					</div>

					<div class="toggle-row">
						{#if welcomeLoaded}
							<div class="toggle-line">
								<Toggle
									label={m.settings_welcome_show_label()}
									bind:checked={welcomeEnabled}
									onchange={handleWelcomeChange}
								/>
								<span
									class="field-status toggle-status"
									class:show={welcomeFlash.status === 'saved'}>{m.common_saved()}</span
								>
							</div>
						{/if}
						<p class="toggle-desc">{m.settings_welcome_show_helper()}</p>
						{#if welcomeFlash.message}
							<p class="field-error" role="alert">{welcomeFlash.message}</p>
						{/if}
					</div>
				</section>
			{/if}

			<section id="settings-chapter-mcp" class="group" aria-labelledby="mcp-heading">
				<div class="group-head">
					<h2 id="mcp-heading" class="group-heading">
						<Plug size={14} stroke-width={1.9} aria-hidden="true" />
						{m.mcp_title()}
					</h2>
					<p class="group-note">{m.mcp_helper()}</p>
				</div>

				<McpEndpoints />
			</section>

			<section id="settings-chapter-sessions" class="group" aria-labelledby="sessions-heading">
				<div class="group-head">
					<h2 id="sessions-heading" class="group-heading">
						<MonitorSmartphone size={14} stroke-width={1.9} aria-hidden="true" />
						{m.sessions_title()}
					</h2>
					<p class="group-note">{m.sessions_helper()}</p>
				</div>

				<Sessions />
			</section>
		</div>
	</div>
</div>

<style>
	/* ── Page — the platform-settings container ──────────────────── */

	.page {
		padding: 28px 32px 48px;
		max-width: 1120px;
		margin: 0 auto;
	}

	.load-error {
		font-size: 13px;
		color: var(--danger);
		background: var(--danger-weak);
		border: 1px solid var(--danger);
		border-radius: var(--r);
		padding: 10px 12px;
		margin: 0 0 16px;
	}

	/* ── Shell — sticky chapter rail + content column ────────────── */

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

	/* ── Group sections ──────────────────────────────────────────── */

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

	/* ── Field grid — two columns, the preview spans both ────────── */

	.group-grid {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 14px 20px;
		align-items: start;
	}

	.field-row {
		display: flex;
		align-items: flex-start;
		gap: 10px;
		min-width: 0;
	}

	.field-main {
		flex: 1;
		min-width: 0;
	}

	.field-status {
		font-size: 11.5px;
		color: var(--ok);
		font-weight: 600;
		opacity: 0;
		transition: opacity 0.15s;
		margin-top: 28px;
		flex: none;
	}

	.field-status.show {
		opacity: 1;
	}

	.field-error {
		font-size: 11.5px;
		color: var(--danger);
		margin: 6px 0 0;
	}

	.tz-preview {
		grid-column: 1 / -1;
		display: flex;
		align-items: baseline;
		gap: 10px;
		padding-top: 12px;
		border-top: 1px solid var(--border);
	}

	.tz-preview-label {
		font-size: 12px;
		color: var(--text-3);
	}

	.tz-preview-time {
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text);
	}

	/* ── Toggle groups ───────────────────────────────────────────── */

	.toggle-row {
		margin: 0;
	}

	.toggle-line {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.toggle-status {
		margin-top: 0;
	}

	.toggle-desc {
		font-size: 11.5px;
		color: var(--text-3);
		margin: 2px 0 0 46px;
	}

	/* ── Narrow viewports ────────────────────────────────────────── */

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
	}
</style>

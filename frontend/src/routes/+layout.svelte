<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { Pathname } from '$app/types';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { invalidateAll, goto } from '$app/navigation';
	import { locales, localizeHref } from '$lib/paraglide/runtime';
	import * as m from '$lib/paraglide/messages';
	import '$lib/styles/tokens.css';
	import '$lib/styles/base.css';
	import './layout.css';
	import favicon from '$lib/assets/facet-favicon.svg';
	import appIcon from '$lib/assets/facet-app-icon.svg';
	import AppShell from '$lib/components/primitives/surfaces/AppShell.svelte';
	import PreviewBanner from '$lib/components/primitives/surfaces/PreviewBanner.svelte';
	import NotificationPanelHost from '$lib/components/primitives/surfaces/NotificationPanelHost.svelte';
	import WelcomeTour from '$lib/components/features/welcome/WelcomeTour.svelte';
	import AssistantHost from '$lib/components/primitives/surfaces/AssistantHost.svelte';
	import PublishDialog from '$lib/components/features/configure/PublishDialog.svelte';
	import ConfirmDialog from '$lib/components/primitives/surfaces/ConfirmDialog.svelte';
	import ToastHost from '$lib/components/primitives/surfaces/ToastHost.svelte';
	import ErrorBoundary from '$lib/components/primitives/surfaces/ErrorBoundary.svelte';
	import NoRoleScreen from '$lib/components/features/auth/NoRoleScreen.svelte';
	import type { NotificationItem } from '$lib/components/primitives/surfaces/NotificationPanel.svelte';
	import { notificationDownloadUrl } from '$lib/notificationDownload.js';
	import { can, getPermissions } from '$lib/permissions.svelte';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import { initTheme } from '$lib/theme.svelte';
	import {
		getNavDomains,
		getNavLiveDomains,
		getDomainLabel,
		rebuildLiveNav,
		rebuildDraftNav,
		rebuildPreviewNav,
		setLiveFromLoad,
		loadBuilderEntryNav
	} from '$lib/navState.svelte';
	import type { PublishDoctypeOption } from '$lib/components/features/configure/PublishDialog.svelte';
	import type { PublishDocumentsSelection } from '$lib/datasource/domainCheck.js';
	import { getCount, loadForDomain } from '$lib/navCounts.svelte';
	import { doctypeViewsCache } from '$lib/datasource/clientCache.js';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
	import { getActiveRole, getAvailableRoles } from '$lib/role.svelte';
	import { switchActiveRole } from '$lib/auth.svelte';
	import {
		loadSettings,
		togglePinnedDoctype,
		getPinnedDoctypes,
		getShowWelcome
	} from '$lib/settings.svelte';
	import {
		getBuilderDraft,
		clearBuilderDraft,
		createDraft,
		createDraftFromSource,
		noteWsInvalidation,
		publishDraft as storePublishDraft,
		type PublishOutcome,
		discardDraft as storeDiscardDraft,
		endPreview as storeEndPreview
	} from '$lib/builderDraft.svelte';
	import {
		isPreviewActive,
		getPreviewSession,
		clearPreviewSession,
		builderPreviewActive,
		previewExpired
	} from '$lib/previewSession.svelte';
	import { subscribeBuilderModel } from '$lib/builderSocket.svelte';
	import {
		setShortcutsHelpOpen,
		handleShortcutKeydown,
		registerGlobalShortcuts
	} from '$lib/shortcuts.svelte';
	import ShortcutsDialog from '$lib/components/primitives/surfaces/ShortcutsDialog.svelte';
	import CommandPalette from '$lib/components/features/search/CommandPalette.svelte';
	import type { PaletteCommand } from '$lib/components/features/search/searchGroups.js';
	import {
		buildCrumbs,
		documentRefOf,
		resolveActiveDoctype,
		builderStatusLabel
	} from '$lib/navCrumbs';
	import { toast } from '$lib/toast.svelte';
	import {
		initAssistantOpen,
		getAssistantOpen,
		toggleAssistantOpen
	} from '$lib/assistantOpen.svelte';
	import { initNotifications, bellProps } from '$lib/notifications.svelte';

	let { data, children } = $props();

	let collapsed = $state(false);
	let activeDomainId = $state('');

	// One open flag drives both assistant surfaces; state + persistence live
	// in `assistantOpen.svelte.ts`, so it survives builder ↔ live navigation.
	// Hydration runs in an effect (post-mount): the server never reads
	// sessionStorage, so a stored-open flag must not change the first client
	// render — that would mismatch the SSR HTML.
	$effect(() => {
		initAssistantOpen();
	});

	// Builder mode is URL-driven: any route under /Builder is in builder mode.
	// The active draft domain comes from the [draftDomain] route param.
	// Configure mode renders its own shell and bypasses AppShell entirely.
	const isBuilderRoute = $derived(page.url.pathname.startsWith('/Builder'));
	const isConfigureRoute = $derived(page.url.pathname.startsWith('/Configure'));
	// OAuth consent renders bare — no AppShell, no sidebar/topbar.
	const isConsentRoute = $derived(page.url.pathname.startsWith('/OAuthConsent'));
	const draftDomain = $derived(page.params.draftDomain ?? getPreviewSession()?.draftId ?? '');

	// Sync activeDomainId from the URL so the sidebar highlights the domain
	// the user is viewing. This drives two cases:
	//   - Builder routes: /Builder/{draftDomain}/... → highlight the draft.
	//   - Live routes: /{domain}/... → highlight the live domain (so a direct
	//     visit to /iam keeps the navbar on `iam`, not on the first domain).
	//
	// The effect reads only URL-derived values (`page.params`, `pathname`) and
	// NOT `activeDomainId`. Subscribing to `activeDomainId` would re-run the
	// effect on every user click in the sidebar (where `NavPanel` writes
	// `activeDomainId` then calls `goto`) and clobber the click with the stale
	// URL before navigation lands. The click writes `activeDomainId` first for
	// immediate doctype-list feedback; once `goto` resolves, this effect
	// re-confirms the same value from the URL — no flicker, no clobber.
	$effect(() => {
		if (isBuilderRoute && draftDomain) {
			activeDomainId = draftDomain;
			return;
		}
		if (isBuilderRoute || isConfigureRoute) return;
		const liveDomain = page.params.domain;
		if (liveDomain) {
			activeDomainId = liveDomain;
		}
	});

	// ── Sidebar domain model ──────────────────────────────────────────────
	//
	// navState owns HOW the model is built; this layout keeps only WHEN:
	// auth, settings readiness, route mode, and the preview carve-out.

	// Pinned doctypes render in the Pinned section and drop out of the
	// Doctypes list.
	let pinnedDoctypes = $state<string[]>([]);
	let settingsReady = $state(false);

	$effect(() => {
		if (typeof window === 'undefined' || settingsReady) return;
		// On unauthenticated routes (e.g. /Login) the SSR load sets
		// `data.authenticated = false`; calling `loadSettings()` here would
		// hit a 401 and `apiFetch`'s default `redirectOnFailure: true` would
		// reload to `/Login` — a self-sustaining loop. Skip the effect until
		// the user is authenticated (after login, an `invalidateAll()`-driven
		// reload flips `data.authenticated` and re-runs this effect).
		if (!data.authenticated) return;
		loadSettings()
			.then((values) => {
				pinnedDoctypes = values.pinnedDoctypes;
				settingsReady = true;
			})
			.catch(() => {
				// Settings are best-effort for the sidebar; fall back to unpinned.
				settingsReady = true;
			});
	});

	// Driver for sidebar-initiated count fetches. Stateless (`DocumentDataDriver`
	// only builds URL paths), so one instance serves the nav-build effect,
	// `NavPanel`'s lazy count loading via AppShell, and the crumb label
	// hydration below.
	const sidebarDriver = new DocumentDataDriver('');

	$effect(() => {
		if (!data.authenticated || !settingsReady || isBuilderRoute) return;
		// While a preview session is active, do not apply the real-user
		// permission manifest to the sidebar rebuild: the draft's doctypes
		// would be filtered out by `computeVisibleDoctypes` and the user
		// would not see their draft's doctypes in the sidebar. The backend's
		// `PreviewEnforcer` is the authority on what the preview principal
		// may read — passing `undefined` mirrors the universal `+layout.ts`.
		const permissions = isPreviewActive() ? undefined : (getPermissions() ?? undefined);
		rebuildLiveNav({ permissions, pinnedDoctypes });
	});

	// Notification channels: start once the session is up (the store dedupes
	// double-inits). Live and Configure both render the bell. Builder has no
	// bell, and the notification routes reject the preview token.
	$effect(() => {
		if (!data.authenticated || isBuilderRoute || isPreviewActive()) return;
		initNotifications();
	});

	// Navigation to a notification's source document stays in the layout
	// (SvelteKit import); the panel host owns the rest of the store wiring.
	// A row that carries the reserved `data.download` key has no source
	// document to open — the click triggers the file download instead (the
	// backend answers with an attachment, so the page stays). The URL is
	// producer-staged; `notificationDownloadUrl` only passes same-origin
	// paths.
	async function handleOpenNotification(item: NotificationItem): Promise<void> {
		const download = notificationDownloadUrl(item);
		if (download) {
			// A backend download endpoint staged by the producer — not an app
			// route, so the `resolve()` rule does not apply here.
			window.location.assign(download);
			return;
		}
		await goto(
			resolve('/[domain=notApi]/[doctype]/[id]', {
				domain: item.domain,
				doctype: item.doc_type,
				id: item.doc_id
			})
		);
	}

	function handleNotificationDownload(item: NotificationItem): void {
		const download = notificationDownloadUrl(item);
		if (!download) return;
		// A backend download endpoint staged by the producer — not an app
		// route, so the `resolve()` rule does not apply here.
		window.location.assign(download);
	}

	// Welcome-tour CTAs hand off to the domain manager: both actions live on
	// the domains page; the import CTA deep-links the import dialog open
	// (?import=1).
	function handleTourNavigate(target: 'create' | 'import'): void {
		if (target === 'import') {
			goto(resolve('/Configure/domains?import=1'));
			return;
		}
		goto(resolve('/Configure/domains'));
	}

	function handlePin(qualified: string) {
		togglePinnedDoctype(qualified)
			.then(() => {
				// Rebuild the live nav so the moved doctype re-renders in the
				// correct section.
				return rebuildLiveNav({
					permissions: getPermissions() ?? undefined,
					pinnedDoctypes: getPinnedDoctypes()
				});
			})
			.catch(() => {});
	}

	$effect(() => {
		if (!data.authenticated) {
			setLiveFromLoad(data.domains);
			return;
		}
		if (isBuilderRoute) {
			// Draft sidebar model + the live-domain list for the EditDomainDialog.
			loadBuilderEntryNav();
		} else {
			// When a preview session is active, skip this branch: the effect at
			// top (keyed on `isPreviewActive()`) rebuilds the nav model with the
			// draft carve-out. Propagating the SSR `data.domains` here would
			// overwrite that rebuild with a stale cookie-session set that filters
			// out the bound draft.
			if (isPreviewActive()) return;
			setLiveFromLoad(data.domains);
		}
	});

	// Mirror navState into local reactive for AppShell consumption.
	const navDomains = $derived(getNavDomains());

	// Read from the reactive stores so the sidebar footer and Switch Role
	// submenu update immediately after a role switch; the `data` snapshot is
	// the fallback until the layout load hydrates the stores.
	const activeRole = $derived(getActiveRole() ?? data.activeRole);
	const availableRoles = $derived(getAvailableRoles() ?? data.availableRoles ?? []);

	// A roleless account connects under the anonymous role (B-120), so
	// `data.authenticated` is true with an empty `available_roles`. There is
	// no workspace to show — the layout renders `NoRoleScreen` instead of the
	// app shell.
	const hasRole = $derived(availableRoles.length > 0);

	$effect(() => {
		if (navDomains.length > 0 && !navDomains.some((d) => d.id === activeDomainId)) {
			activeDomainId = navDomains[0]?.id ?? '';
		}
	});

	// Signal-only handler: a permissions-update event means "the session's
	// role / permissions / scopes may have changed — re-derive everything from
	// the server". `invalidateAll()` re-runs the root layout load, which writes
	// the fresh `/Api/iam/me` result back into the role / permission / scope
	// stores; reading `event.detail` instead would leave `scopes` stale.
	onPermissionRefresh(() => invalidateAll());

	// Crumbs, the active doctype qualifier, and the builder status line come
	// from the pure helpers in `navCrumbs.ts`; the `getDomainLabel` read tracks
	// the navState store, so every derived re-runs when the model loads.
	const activeDoctype = $derived(
		resolveActiveDoctype(page.url.pathname, navDomains, isBuilderRoute)
	);

	// The document-id crumb resolves through a small label cache. The effect
	// hydrates the id segment of the current live document route with one
	// `show()` round trip and writes `meta.display_name ?? id` into the map —
	// the same label rule the show page's h1 uses. The driver's `documentShowCache`
	// dedupes against the page's own fetch, so on the show route this is a cache
	// hit. A failed resolve (lost grant, gone document) keeps the raw id. The
	// effect reads no `$state` map on purpose: a tracked read here plus the
	// label write below would re-run this very effect on every landing (see
	// `doc/frontend/workflow.md` → "The equality-guard trap in writeback
	// effects"). It re-resolves on every navigation to a document route, so a
	// renamed document shows its new label. The in-flight set is a plain `Set`:
	// plain collections do not subscribe on read and do not trigger on write.
	const docLabels = $state<Record<string, string>>({});
	const crumbLabelsInFlight = new Set<string>();
	$effect(() => {
		if (!data.authenticated) return;
		if (isBuilderRoute || isConfigureRoute || isConsentRoute) return;
		const ref = documentRefOf(page.url.pathname, false);
		if (ref === null) return;
		if (crumbLabelsInFlight.has(ref.id)) return;
		crumbLabelsInFlight.add(ref.id);
		sidebarDriver
			.domain(ref.domain)
			.doctype(ref.doctype)
			.doc(ref.id)
			.show()
			.then((res) => {
				docLabels[ref.id] = res.meta.display_name ?? ref.id;
			})
			.catch(() => {
				// No readable label — the crumb keeps the raw id. The recents
				// store stays untouched: the dashboard and the palette own it.
			})
			.finally(() => {
				crumbLabelsInFlight.delete(ref.id);
			});
	});

	const crumbs = $derived(
		buildCrumbs(page.url.pathname, {
			isBuilderRoute,
			labelFor: getDomainLabel,
			// Sync lookup over the hydrated label map; the raw id stands in
			// while the label is unknown.
			docLabelFor: (id) => docLabels[id] ?? id
		})
	);
	const builderMessage = $derived(builderStatusLabel(isBuilderRoute, activeDomainId, navDomains));

	// Which assistant mount (if any) the current route gets. The workspace
	// mount is gated on `assistantAccess` so a stale persisted open state never
	// mounts a window for an account whose roles lost their `assistant_access`
	// flag (the backend gates the routes as well). The workspace surface serves
	// the live application and the Configure shell alike: both are signed-in
	// role-scoped surfaces, and the backend gates the workspace routes on
	// `assistant_access`, not on the route. During an active preview session the
	// mount stays the builder one: the user is looking at the draft's live URL
	// but is still iterating on the draft with the assistant, and the preview
	// token would fail the workspace surface's role gates anyway (the
	// capability principal carries no active role). The builder conversation
	// binds to the preview domain — see the domain-builder create route's
	// preview branch.
	const assistantSurface = $derived.by(() => {
		if (!data.authenticated) return null;
		if (isBuilderRoute) return 'builder' as const;
		if (isPreviewActive()) return 'builder' as const;
		if (!isConsentRoute && data.assistantAccess) {
			return 'workspace' as const;
		}
		return null;
	});

	// ── Draft creation handlers (builder mode authoring actions) ───────────
	//
	// `createDraft` / `createDraftFromSource` own the API call, the sidebar
	// install, and the WS-invalidation settle; this layout owns the
	// navigation and the inline error state.
	let editError = $state<string | undefined>(undefined);

	async function handleNewDomain(input: { name: string; label?: string }): Promise<string | null> {
		const result = await createDraft(input);
		if (result.error) {
			toast({ message: result.error, variant: 'error' });
			return result.error;
		}
		if (!result.draftId) return m.builder_draft_network_error();
		goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: result.draftId }));
		return null;
	}

	async function handleEditDomain(sourceId: string): Promise<void> {
		editError = undefined;
		const result = await createDraftFromSource(sourceId);
		if (result.error) {
			editError = result.error;
			toast({ message: result.error, variant: 'error' });
			return;
		}
		if (!result.draftId) {
			editError = m.builder_draft_network_error();
			return;
		}
		goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: result.draftId }));
	}

	function handleExitBuilder() {
		goto(resolve('/'));
	}

	// ── Builder top-bar state ────────────────────────────────────────────────────
	//
	// Publish dialog open is a local `$state` because PublishDialog binds it
	// two-way (Cancel and submit-success set it false); keeping it local avoids
	// a bindable → store bridge. The `builderDraft` store carries the draft's
	// read-only snapshot.

	const draftSnapshot = $derived(getBuilderDraft());
	const builderDraftName = $derived(draftSnapshot.name || undefined);
	const builderIsDraft = $derived(draftSnapshot.isDraft);
	const builderCheckIssueCount = $derived(draftSnapshot.checkIssueCount);
	let publishOpen = $state(false);

	// Command palette open state. The Configure shell mounts its own palette
	// (with its own command list); the guard on this mount keeps the two
	// apart, so only one Cmd/Ctrl+K listener exists at a time.
	let paletteOpen = $state(false);

	// Preview is URL-derived: any /Builder/[draft]/preview/* path is preview
	// mode; when the token-backed overlay is active the segmented toggle hides
	// in favour of the PreviewBanner.
	const previewSession = $derived(getPreviewSession());
	const builderIsPreview = $derived(builderPreviewActive(page.url.pathname));

	function selectBuild() {
		if (!isBuilderRoute || !draftDomain) return;
		const segs = page.url.pathname.split('/').filter(Boolean);
		if (segs.length >= 3 && segs[2] === 'preview') {
			goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain }));
		}
		// Otherwise the user is already on a build-route tab — no-op.
	}

	function selectPreview() {
		if (!isBuilderRoute || !draftDomain) return;
		// Enter through the preview entry page: it issues the capability token
		// and navigates to the draft's live URL. Issuing here would trip the
		// preview-lifecycle effect below — at issuance time the URL is still a
		// builder editor URL, which `previewExpired` treats as expired, so the
		// token would be cleared before the navigation lands (the live page
		// would 404).
		goto(resolve('/Builder/[draftDomain]/preview/[...path]', { draftDomain, path: '' }));
	}

	function handlePublishClick() {
		if (draftSnapshot.isDraft) publishOpen = true;
	}

	async function handleDiscardClick() {
		const err = await storeDiscardDraft();
		if (err) {
			editError = err;
		} else {
			clearBuilderDraft();
			publishOpen = false;
		}
	}

	async function handlePublishDialog(
		targetName: string,
		overwrite: boolean,
		documents?: PublishDocumentsSelection
	): Promise<PublishOutcome> {
		const outcome = await storePublishDraft(targetName, overwrite, documents);
		if (outcome.status === 'published' && !outcome.report) {
			// Success. The draft is dropped server-side; the snapshot is stale.
			// With tickets the dialog stays on its report — clearing the draft
			// store here would drop `draftSnapshot.isDraft` and unmount the
			// dialog with the report still unread (the dialog host renders only
			// while the snapshot is a draft). The snapshot survives until the
			// user leaves the report; that navigation exits the builder route,
			// and the leaving effect below clears the store.
			clearBuilderDraft();
			publishOpen = false;
		}
		return outcome;
	}

	/** Leaves the publish dialog's ticket report and lands on the published
	 *  domain — the only exit: the draft URL behind the dialog is dead. */
	async function handlePublishContinue(domain: string): Promise<void> {
		publishOpen = false;
		await goto(resolve('/[domain=notApi]', { domain }));
	}

	// The publish dialog's documents block lists the active draft's doctypes
	// with the row count each holds. A doctype the live target already defines
	// is flagged `exists` so the dialog disables its checkbox: the backend
	// refuses to import draft rows into a production doctype.
	const publishDoctypeOptions = $derived.by((): PublishDoctypeOption[] => {
		if (!draftSnapshot.isDraft) return [];
		const draft = navDomains.find((d) => d.id === draftSnapshot.id);
		if (!draft) return [];
		const live = getNavLiveDomains().find((d) => d.id === draftSnapshot.publishName.trim());
		const liveNames = new Set(live?.doctypes.map((dt) => dt.label) ?? []);
		return draft.doctypes.map((dt) => ({
			name: dt.label,
			count: getCount(dt.qualified) ?? 0,
			exists: liveNames.has(dt.label)
		}));
	});

	// Counts load lazily for the active domain; the documents block reads
	// them, so request them while a draft is open in the builder.
	$effect(() => {
		if (!publishOpen || !draftSnapshot.isDraft) return;
		const draft = navDomains.find((d) => d.id === draftSnapshot.id);
		if (!draft || draft.doctypes.length === 0) return;
		void loadForDomain(new DocumentDataDriver(''), draft.doctypes);
	});

	// Reset the store when leaving the builder subtree. Without this, stale
	// state from a prior draft lingers on the top bar during /Configure or /Live
	// navigation (the top bar is hidden there, but the store mutation would
	// affect the next builder entry).
	$effect(() => {
		if (!isBuilderRoute) {
			clearBuilderDraft();
			publishOpen = false;
		}
	});

	// Preview overlay lifecycle: clear when the user navigates outside the
	// bound draft domain — a stale token would 401 every request. The URL
	// matching lives in `previewExpired`; the user can re-enter preview from
	// the Builder.
	$effect(() => {
		const active = getPreviewSession();
		if (active && previewExpired(active, page.url.pathname)) clearPreviewSession();
	});

	// ── WebSocket: refresh the draft model when something mutates it ──────────
	//
	// Runs in two modes. On builder routes the handler refreshes the draft
	// sidebar. During an active preview session the user sits on the draft's
	// live URL, so the same subscription (the socket is cookie-authenticated —
	// the real principal, exactly like the builder editor's) keeps the preview
	// hot: a doctype the assistant adds or removes from the chat window lands
	// in the sidebar and the open page without a manual refresh. Collection
	// messages are hints, not source of truth: rebuild from the server, never
	// from the event payload. The cache drops live inside the rebuild helpers
	// (navState.svelte.ts). Do not read nav state here — a tracked read would
	// re-run the effect (unsubscribe → resubscribe churn) every time the
	// handler rebuilds the nav model.
	function handleWsModelChange() {
		// A live frame carries no doctype identity, so drop every cached view
		// template list. The loads re-run below and re-fetch.
		doctypeViewsCache.clear();
		noteWsInvalidation(invalidateAll());
		rebuildDraftNav();
	}

	function handlePreviewModelChange() {
		// A late event can land after the session cleared (the layout's
		// preview-expired effect runs first) — the rebuild's preview carve-out
		// reads `getPreviewSession()`, so it must not run without one.
		if (!isPreviewActive()) return;
		rebuildPreviewNav(getPinnedDoctypes());
		void invalidateAll();
	}

	$effect(() => {
		if (!data.authenticated) return;
		const preview = getPreviewSession();
		const onBuilder = isBuilderRoute;
		if (!onBuilder && !preview) return;
		const draftId = onBuilder ? draftDomain : (preview?.draftId ?? '');
		if (!onBuilder && !draftId) return;
		return subscribeBuilderModel({
			draftDomain: draftId,
			onModelChange: onBuilder ? handleWsModelChange : handlePreviewModelChange
		});
	});

	// Apply stored theme on mount (pre-paint inline script in app.html prevents FOUC).
	initTheme();

	// ── Keyboard shortcuts ────────────────────────────────────────────────
	//
	// One dispatcher on `window` (see `$lib/shortcuts.svelte.ts`). The layout
	// owns the global scope; pages and heavy components register their own
	// route-scoped entries and clean up on destroy. Registration re-runs only
	// when a read dependency changes — the handlers themselves resolve state
	// at keypress time, so normal toggles never re-register.
	$effect(() => {
		if (!data.authenticated) return;
		return registerGlobalShortcuts([
			{
				id: 'app.assistant',
				keys: 'Mod+I',
				label: m.shortcuts_toggle_assistant(),
				group: 'general',
				// Consent and unauthenticated routes have no assistant surface — the
				// key stays inert there instead of opening a window that cannot mount.
				when: () => assistantSurface !== null,
				handler: () => {
					toggleAssistantOpen();
					return true;
				}
			},
			{
				id: 'app.sidebar',
				keys: 'Mod+\\',
				label: m.shortcuts_toggle_sidebar(),
				group: 'general',
				handler: () => {
					collapsed = !collapsed;
					return true;
				}
			},
			{
				id: 'app.help',
				keys: '?',
				label: m.shortcuts_show_help(),
				group: 'general',
				handler: () => {
					setShortcutsHelpOpen(true);
					return true;
				}
			}
		]);
	});

	// ── Command palette ──────────────────────────────────────────────
	//
	// Jump entries first: the Navigate group only carries the nav model
	// (domains + doctypes), so the pages outside the workspace ride the
	// Actions group as commands — the same pattern the Configure shell uses
	// for its sections. Each jump reuses the gate its sidebar twin applies,
	// so the palette never offers a page the sidebar hides. Then the
	// layout's own actions; the assistant entry mirrors its shortcut gate
	// (no surface, no entry). Draft creation stays out on purpose: the
	// Builder landing's dialog is the only flow that collects a name, and a
	// palette command would silently create an unnamed draft.
	// Jump icons reuse the menu twins' Lucide marks (kebab-case); commands
	// without a menu twin (sidebar, help) leave `icon` unset and render the
	// signature diamond. The assistant reuses its top-bar pill's sparkles.
	const paletteCommands = $derived.by<PaletteCommand[]>(() => {
		// The load fail-closes to an empty list — a browser-only role hides
		// the channel-gated entries, same rule as SidebarShell's footer.
		const connectivity = data.connectivity;
		const jumps: PaletteCommand[] = [
			{
				id: 'app.goto.builder',
				label: m.builder_title(),
				icon: 'hard-hat',
				run: () => {
					goto(resolve('/Builder'));
				}
			}
		];
		if (can('core.DocType', 'update')) {
			jumps.push({
				id: 'app.goto.configure',
				label: m.nav_configure(),
				icon: 'settings',
				run: () => {
					goto(resolve('/Configure/domains'));
				}
			});
		}
		jumps.push({
			id: 'app.goto.apps',
			label: m.configure_apps_title(),
			icon: 'app-window',
			run: () => {
				goto(resolve('/Configure/apps'));
			}
		});
		if (can('core.SystemSettings', 'read')) {
			jumps.push({
				id: 'app.goto.system-settings',
				label: m.system_settings_page_header(),
				icon: 'sliders-horizontal',
				run: () => {
					goto(resolve('/Configure/platform/settings'));
				}
			});
		}
		jumps.push({
			id: 'app.goto.my-settings',
			label: m.nav_my_settings(),
			icon: 'user',
			run: () => {
				goto(resolve('/Settings'));
			}
		});
		if (connectivity.includes('api')) {
			jumps.push({
				id: 'app.goto.api-keys',
				label: m.nav_api_keys(),
				icon: 'key-round',
				run: () => {
					goto(resolve('/Settings/api-keys'));
				}
			});
		}
		if (connectivity.includes('webhook')) {
			jumps.push({
				id: 'app.goto.webhooks',
				label: m.nav_webhooks(),
				icon: 'webhook',
				run: () => {
					goto(resolve('/Settings/webhooks'));
				}
			});
		}

		const list: PaletteCommand[] = [
			{
				id: 'app.sidebar',
				label: m.shortcuts_toggle_sidebar(),
				run: () => {
					collapsed = !collapsed;
				}
			},
			{
				id: 'app.help',
				label: m.shortcuts_show_help(),
				run: () => setShortcutsHelpOpen(true)
			}
		];
		if (assistantSurface !== null) {
			list.push({
				id: 'app.assistant',
				label: m.shortcuts_toggle_assistant(),
				icon: 'sparkles',
				run: () => toggleAssistantOpen()
			});
		}
		return [...jumps, ...list];
	});
</script>

<!-- Single keyboard dispatcher — routes keydowns to the shortcut registry. -->
<svelte:window onkeydown={handleShortcutKeydown} />

<svelte:head>
	<link rel="icon" href={favicon} />
	<link rel="apple-touch-icon" href={appIcon} />
</svelte:head>

<!-- Last-resort boundary: catches crashes in the shells and the global hosts.
	Page-content crashes are caught by the inner boundaries below, so the
	sidebar stays alive. A navigation (menu click, browser back) or Retry
	auto-recovers by remounting the boundary. -->
<ErrorBoundary level="app">
	{#if data.authenticated && isConfigureRoute}
		<!-- Configure mode owns its own shell (sidebar + topbar) and bypasses
		AppShell. AppShell's builder-mode assistant / draft-state controls
		belong to the Builder subtree, not the Configure subtree. -->
		<ErrorBoundary>{@render children?.()}</ErrorBoundary>
	{:else if data.authenticated && isConsentRoute}
		<!-- OAuth consent is a standalone surface — render the page bare with no
		application chrome. -->
		<ErrorBoundary>{@render children?.()}</ErrorBoundary>
	{:else if data.authenticated && !hasRole}
		<!-- Roleless account (B-120): the backend lets it connect under the
		anonymous role, but there is no workspace to show. The refresh re-runs
		the layout load so a freshly granted role is picked up. -->
		<NoRoleScreen onrefresh={() => invalidateAll()} />
	{:else if data.authenticated}
		{#if previewSession}
			<!-- Preview overlay: render the banner above AppShell so the user
			knows they're in a throwaway draft and can exit back to the
		Builder editor. AppShell's children render the live application's
		list/table/show/form surfaces against the draft's data, authorised
		by the Bearer token injected by `apiFetch`. -->
			<PreviewBanner
				draftId={previewSession.draftId}
				label={getDomainLabel(previewSession.draftId)}
				onexit={() => storeEndPreview()}
			/>
		{/if}
		<AppShell
			bind:collapsed
			bind:activeDomainId
			domains={navDomains}
			{activeDoctype}
			account={data.account}
			{activeRole}
			{availableRoles}
			connectivity={data.connectivity}
			onSwitchRole={async (role) => {
				await switchActiveRole(role);
			}}
			{crumbs}
			builderMode={isBuilderRoute}
			{builderMessage}
			onexitbuilder={handleExitBuilder}
			{builderDraftName}
			{builderIsDraft}
			{builderIsPreview}
			{builderCheckIssueCount}
			onselectbuild={selectBuild}
			onselectpreview={selectPreview}
			onpublish={handlePublishClick}
			ondiscard={handleDiscardClick}
			ontoggleassistant={toggleAssistantOpen}
			assistantOpen={getAssistantOpen()}
			assistantAvailable={data.assistantAccess}
			assistantLabel={data.assistantName}
			liveDomains={getNavLiveDomains()}
			onnewdomain={handleNewDomain}
			oneditdomain={handleEditDomain}
			{editError}
			onpin={handlePin}
			driver={sidebarDriver}
			{...bellProps()}
			showSearch
			onsearch={() => (paletteOpen = true)}
		>
			<ErrorBoundary>{@render children?.()}</ErrorBoundary>
		</AppShell>
	{:else}
		<ErrorBoundary>{@render children?.()}</ErrorBoundary>
	{/if}

	<!-- Notification panel host — one mount for both shells that render the
	Topbar bell (live and Configure). Consent renders bare and Builder has
	no bell, so the panel can open only where the bell exists. -->
	{#if data.authenticated && !isConsentRoute && hasRole}
		<NotificationPanelHost
			onnavigate={handleOpenNotification}
			ondownload={handleNotificationDownload}
		/>
		<!-- First-run tour for admins — opens when the active role is the seeded
		admin and `core.show_welcome` is true. `getShowWelcome()` is a tracked
		store read: the prop updates when the settings load resolves. -->
		<WelcomeTour {activeRole} showWelcome={getShowWelcome()} onNavigate={handleTourNavigate} />
	{/if}

	<!-- Command palette — one mount for the live and Builder shells, guarded
	like the notification host so it never runs alongside the Configure
	palette (that shell mounts its own, with its own command list). -->
	{#if data.authenticated && !isConfigureRoute && !isConsentRoute && hasRole}
		<CommandPalette
			bind:open={paletteOpen}
			commands={paletteCommands}
			activeDomain={activeDomainId}
		/>
	{/if}

	<!-- Global confirmation dialog host — backs `confirm()` from `$lib/confirm.svelte`.
	Rendered unconditionally so any route (including Configure and login) can ask. -->
	<ConfirmDialog />

	<!-- Global toast host — backs `toast()` from `$lib/toast.svelte`. -->
	<ToastHost />

	<!-- Keyboard-shortcut cheat sheet — opened with `?`; lists the active
		global + route-scoped entries from the registry. -->
	<ShortcutsDialog />

	<!-- Assistant window mount. Position:fixed, so it floats over AppShell
	regardless of the grid layout; rendered outside AppShell so the
	AppShell's grid no longer needs the 3rd assistant column. The configured
	name rides down to both surfaces — workspace and builder show one name.
	`assistantConfigured` reports whether an API key resolves; false keeps the
	dock visible but disables conversation creation with an explanation. -->
	<AssistantHost
		surface={assistantSurface}
		{draftDomain}
		accountId={data.account?.id ?? ''}
		name={data.assistantName}
		assistantConfigured={data.assistantConfigured}
	/>

	{#if data.authenticated && isBuilderRoute && (draftSnapshot.isDraft || publishOpen)}
		<!-- Publish dialog host. Previously lived inside DomainEditor; the
		configure UX brief consolidated publish into the top bar, so the dialog
		is hosted at the root layout to portal over AppShell and stay open
		regardless of which tab the user is on. The `publishOpen` arm keeps the
		dialog mounted through a published draft's teardown: the WS-driven
		invalidate reloads the editor page, DomainEditor pushes isDraft:false
		for the dropped draft, and without this arm the ticket report would
		unmount before it renders. -->
		<PublishDialog
			bind:open={publishOpen}
			draftDomain={draftSnapshot.id}
			initialName={draftSnapshot.publishName}
			check={draftSnapshot.check}
			doctypes={publishDoctypeOptions}
			onpublish={handlePublishDialog}
			oncontinue={handlePublishContinue}
		/>
	{/if}
</ErrorBoundary>

<div style="display:none">
	{#each locales as locale (locale)}
		<a href={resolve(localizeHref(page.url.pathname, { locale }) as Pathname)}>{locale}</a>
	{/each}
</div>

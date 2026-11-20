<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto, invalidate, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { History as HistoryIcon, Pencil, Printer, Share2, Check } from '@lucide/svelte';
	import DocumentViewTemplate from '$lib/components/features/document-view/DocumentViewTemplate.svelte';
	import DvtValue from '$lib/components/features/document-view/DvtValue.svelte';
	import ActionArgsDialog, {
		argControl
	} from '$lib/components/features/document-view/ActionArgsDialog.svelte';
	import QuickViewHost from '$lib/components/primitives/surfaces/QuickViewHost.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import DoctypeHeader from '$lib/components/primitives/content/DoctypeHeader.svelte';
	import type { MenuItem } from '$lib/components/primitives/actions/DropdownMenu.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import AccountCredentialActions from '$lib/components/features/admin/AccountCredentialActions.svelte';
	import { documentDependencyKey, subscribeDocumentRefresh } from '$lib/documentSocket.svelte.js';
	import BacklinksPanel from '$lib/components/features/document-view/BacklinksPanel.svelte';
	import SidecarPanel from '$lib/components/features/document-view/SidecarPanel.svelte';
	import { can } from '$lib/permissions.svelte';
	import { toast } from '$lib/toast.svelte.js';
	import { recordRecentDocument } from '$lib/recentDocuments.svelte';
	import { isTypingTarget, registerRouteShortcuts } from '$lib/shortcuts.svelte';
	import type { DocumentResponse } from '$lib/datasource/types';
	import { toBannerError, type BannerError } from '$lib/datasource/bannerError.js';
	import type { TemplateNode } from '$lib/template-types';
	import { fieldDefFor, resolveValue } from '$lib/template-resolve';
	import DvtRelation from '$lib/components/features/document-view/DvtRelation.svelte';
	import { buildFallbackChildRelations } from '$lib/components/features/document-view/fallbackChildRelations.js';
	import { humanize, actionStateAllowed, type ActionDef } from '$lib/doctype/types.js';
	import * as m from '$lib/paraglide/messages';

	let { data } = $props();

	const def = $derived(data.def);
	const doc = $derived(data.doc as DocumentResponse<Record<string, unknown>>);
	const view = $derived(data.view as { kind: string; template: TemplateNode | null });
	/** Qualified name (`"crm.Contact"`) — the `core.DocType` projection id, used as
	 *  the QuickView's root parent id for quickView-template lookups. */
	const qualifiedName = $derived(data.qualifiedName as string);

	/** Declared sidecar relationships — drives the right-side rail. When the
	 *  host def declares none the layout stays single-column. */
	const sidecarEntries = $derived(def.sidecars ?? []);

	/** Fallback children (no view template): one read-only relation section
	 *  per `def.children` entry — the same builder the fallback form uses for
	 *  its editable sections, minus the drafts machinery. Memoised in the
	 *  derived so a re-render does not hand `DvtRelation` a fresh template
	 *  and re-fetch its rows. */
	const fallbackChildRelations = $derived.by(() => buildFallbackChildRelations(def, false));

	const historyHref = $derived(
		resolve('/[domain=notApi]/[doctype]/[id]/history', {
			domain: encodeURIComponent(def.domain),
			doctype: encodeURIComponent(def.doctype),
			id: encodeURIComponent(doc.meta.id)
		})
	);
	const editHref = $derived(
		resolve('/[domain=notApi]/[doctype]/[id]/edit', {
			domain: encodeURIComponent(def.domain),
			doctype: encodeURIComponent(def.doctype),
			id: encodeURIComponent(doc.meta.id)
		})
	);

	// Custom action menu: only show actions the active role holds on the
	// doctype. Delete is folded into this menu (with a confirm) so the page's
	// only solid action is Edit; the destructive action is demoted out of the
	// primary visual path. Actions with required arguments open the args
	// prompt (ActionArgsDialog) and submit the collected args with the action
	// call. The menu item stays disabled with the "(args required)" suffix
	// only when a required arg type has no input renderer — the prompt cannot
	// collect it. Record this document in the browser's recently-viewed list
	// (localStorage). Runs once per navigation, browser-only. The layout
	// dashboard reads this list to surface quick-access chips for the active
	// domain.
	//
	// A plain-`let` shadow keyed on the doc id guards the write:
	// `recordRecentDocument` reads the module-level `documents` `$state` to
	// dedupe, and then writes it. Without the shadow, the effect would
	// subscribe to `documents`, write it, re-run, and loop infinitely (see
	// `doc/frontend/workflow.md` → "The equality-guard trap in writeback
	// effects"). The shadow only suppresses redundant writes for the same
	// document — a navigation to a different doc id re-seeds it.
	// svelte-ignore state_referenced_locally — intentional initial value.
	let lastRecordedId: string | undefined;
	$effect(() => {
		if (typeof window === 'undefined') return;
		const meta = doc.meta;
		if (meta.id === lastRecordedId) return;
		lastRecordedId = meta.id;
		recordRecentDocument({
			id: meta.id,
			domain: meta.domain,
			doctype: meta.doc_type
		});
	});

	const actionMenuItems = $derived.by<MenuItem[]>(() => {
		const out: MenuItem[] = [];
		if (can(qualifiedName, 'delete')) {
			out.push({
				label: m.common_delete(),
				variant: 'danger',
				onclick: () => deleteDoc()
			});
		}
		for (const act of def.actions) {
			if (!can(qualifiedName, act.key)) continue;
			// State gate: the definition limits the action to some document
			// states — the entry hides when the current content does not match.
			if (!actionStateAllowed(act, doc.data)) continue;
			// Declared label wins; otherwise humanize the key ("move_stage" →
			// "Move Stage") so raw snake_case never reaches the UI.
			const label = act.label ?? humanize(act.key);
			// A required arg with no input renderer cannot be collected
			// client-side — the item stays a disabled "(args required)" entry.
			const hasUnrenderableRequiredArg = act.args.some((a) => a.required && argControl(a) === null);
			if (hasUnrenderableRequiredArg) {
				out.push({
					label: m.doc_action_args_required({ label }),
					title: act.description,
					disabled: true,
					onclick: () => triggerAction(act.key)
				});
				continue;
			}
			const needsArgs = act.args.some((a) => a.required);
			out.push({
				label,
				title: act.description,
				onclick: () => {
					if (!needsArgs) {
						void triggerAction(act.key);
						return;
					}
					argsAction = act;
					actionError = null;
					argsDialogOpen = true;
				}
			});
		}
		return out;
	});
	const showActionsDropdown = $derived(actionMenuItems.length > 0);

	/** The action whose arguments the args prompt collects, `null` when closed. */
	let argsAction: ActionDef | null = $state(null);
	let argsDialogOpen = $state(false);
	/** The last action failure, rendered in the args prompt or the page banner. */
	let actionError = $state<BannerError | null>(null);

	/** The args prompt collected the values — run the action and close on success. */
	async function submitActionArgs(args: Record<string, unknown>): Promise<boolean> {
		const act = argsAction;
		if (!act) return false;
		const ok = await triggerAction(act.key, args);
		if (ok) {
			argsDialogOpen = false;
			argsAction = null;
		}
		return ok;
	}

	async function triggerAction(
		actionKey: string,
		args: Record<string, unknown> = {}
	): Promise<boolean> {
		actionError = null;
		try {
			await data.driver
				.domain(def.domain)
				.doctype(def.doctype)
				.doc(doc.meta.id)
				.action(actionKey, args);
			// Refresh the show page so the updated content/version are visible.
			await invalidateAll();
			toast({ message: m.doc_action_toast(), variant: 'ok' });
			return true;
		} catch (e) {
			// Surface the backend's structured details: the args prompt renders
			// them while it stays open, and the page banner covers the no-args
			// path. The toast keeps the failure visible over the modal.
			const banner = toBannerError(e);
			actionError = banner;
			toast({
				message:
					banner.details.length > 0
						? `${banner.message}: ${banner.details.join('; ')}`
						: banner.message,
				variant: 'error'
			});
			console.error(`Action ${actionKey} failed:`, e);
			return false;
		}
	}

	/** Refresh the show page's document data.
	 *
	 * The ref's own mutation paths invalidate the cached `show()` themselves,
	 * but anything that bypasses the datasource does not: the credential
	 * panel's bespoke IAM endpoints, a mutation from a second tab, an
	 * automation. Drop the cached projection first, then re-run THIS route's
	 * load through the declared dependency — `invalidateAll` alone re-ran the
	 * load into the still-warm 60s show cache and the document section kept
	 * the pre-mutation values (B-89: stale `must_change_pw`).
	 */
	function refreshDocument(): void {
		data.driver.domain(def.domain).doctype(def.doctype).doc(doc.meta.id).invalidate();
		void invalidate(documentDependencyKey(doc.meta.id));
	}

	// Live document refresh: the per-document WebSocket channel re-runs the
	// load when any actor mutates the document — no manual reload. The
	// credential panel's explicit `onchanged` stays the guarantee for the
	// operator's own action (channel delivery is at-most-once, no replay);
	// the channel heals everyone else. Navigation to another document
	// resubscribes through the effect's dependency on `doc.meta.id`.
	$effect(() => {
		if (typeof window === 'undefined') return;
		return subscribeDocumentRefresh({
			domain: def.domain,
			docType: def.doctype,
			docId: doc.meta.id,
			refresh: refreshDocument
		});
	});

	async function deleteDoc(): Promise<void> {
		// Backlinks are informational — fetched before the confirm so the dialog
		// can warn "N documents reference this". A failed lookup (no read grant
		// on a referrer doctype, offline) falls back to the plain confirm; delete
		// is never blocked by referring documents.
		let backrefCount = 0;
		try {
			const refs = await data.driver
				.domain(def.domain)
				.doctype(def.doctype)
				.doc(doc.meta.id)
				.backrefs();
			backrefCount = refs.data.length;
		} catch {
			// Fall through to the plain confirm.
		}
		// Destructive action: confirm before issuing the delete. Keeps the route
		// explicit (no risky silent path) and matches the redesign brief: Delete
		// is demoted into the Actions menu with a confirm gate.
		const name = doc.meta.display_name ?? doc.meta.id;
		const confirmed = window.confirm(
			backrefCount > 0
				? m.doc_delete_confirm_referenced({ name, count: backrefCount })
				: m.doc_delete_confirm({ name })
		);
		if (!confirmed) return;
		try {
			await data.driver.domain(def.domain).doctype(def.doctype).doc(doc.meta.id).delete();
			await goto(
				resolve('/[domain=notApi]/[doctype]', {
					domain: encodeURIComponent(def.domain),
					doctype: encodeURIComponent(def.doctype)
				})
			);
		} catch (e) {
			console.error('Delete failed:', e);
			throw e;
		}
	}

	let shareCopied = $state(false);
	let shareResetTimer: ReturnType<typeof setTimeout> | undefined;

	async function shareDoc(): Promise<void> {
		try {
			await navigator.clipboard.writeText(window.location.href);
			shareCopied = true;
			clearTimeout(shareResetTimer);
			shareResetTimer = setTimeout(() => (shareCopied = false), 1500);
		} catch (e) {
			console.error('Share failed:', e);
		}
	}

	function printDoc(): void {
		window.print();
	}

	// `E` opens the edit form — gated on the update permission, mirroring the
	// rendered Edit button. Bare keys stay off while typing, and the dialog
	// guard in the dispatcher keeps it out of modal surfaces.
	$effect(() => {
		if (!can(qualifiedName, 'update')) return;
		return registerRouteShortcuts([
			{
				id: 'doc.edit',
				keys: 'E',
				label: m.shortcuts_doc_edit(),
				group: 'document',
				when: (e) => !isTypingTarget(e.target),
				handler: () => {
					// editHref is built with `resolve()` at the source (a derived in
					// this component); the rule cannot see through the derived, so
					// this navigation carries the standard leaf-disable comment.
					// eslint-disable-next-line svelte/no-navigation-without-resolve -- editHref is a `resolve()`-built href from a $derived, invisible to the rule.
					void goto(editHref);
					return true;
				}
			}
		]);
	});
</script>

<svelte:head>
	<title
		>{m.doc_page_title({
			name: doc.meta.display_name ?? doc.meta.id,
			doctype: def.doctype,
			domain: def.domain
		})}</title
	>
</svelte:head>

<QuickViewHost driver={data.driver} rootDef={def} rootParentDocId={qualifiedName}>
	{#snippet trigger(api)}
		<div class="doctype-show">
			<DoctypeHeader
				title={doc.meta.display_name ?? doc.meta.id}
				color={def.color}
				backHref={resolve('/[domain=notApi]/[doctype]', {
					domain: encodeURIComponent(def.domain),
					doctype: encodeURIComponent(def.doctype)
				})}
				backLabel={def.doctype}
				version={doc.meta.version}
				{qualifiedName}
			>
				{#snippet actions()}
					<Button variant="ghost" size="sm" onclick={shareDoc} title={m.doc_copy_link_title()}>
						{#snippet iconLeft()}
							{#if shareCopied}
								<Check size={14} strokeWidth={2} aria-hidden="true" />
							{:else}
								<Share2 size={14} strokeWidth={2} aria-hidden="true" />
							{/if}
						{/snippet}
						{shareCopied ? m.common_copied() : m.doc_share()}
					</Button>

					<Button variant="ghost" size="sm" onclick={printDoc} title={m.doc_print_title()}>
						{#snippet iconLeft()}
							<Printer size={14} strokeWidth={2} aria-hidden="true" />
						{/snippet}
						{m.doc_print()}
					</Button>

					<Button href={historyHref} variant="ghost" size="sm">
						{#snippet iconLeft()}
							<HistoryIcon size={14} strokeWidth={2} aria-hidden="true" />
						{/snippet}
						{m.doc_history()}
					</Button>

					<Can doctype={qualifiedName} action="update">
						<Button href={editHref} variant="primary" size="sm">
							{#snippet iconLeft()}
								<Pencil size={14} strokeWidth={2} aria-hidden="true" />
							{/snippet}
							{m.common_edit()}
						</Button>
					</Can>

					{#if showActionsDropdown}
						<Button variant="ghost" size="sm" caret menu={actionMenuItems}>{m.doc_actions()}</Button
						>
					{/if}
				{/snippet}
			</DoctypeHeader>

			{#if actionError && !argsDialogOpen}
				<AlertBanner
					message={actionError.message}
					details={actionError.details}
					dismissable
					onDismiss={() => (actionError = null)}
				/>
			{/if}

			<div class="show-body" class:with-sidecars={sidecarEntries.length > 0}>
				<div class="show-content">
					{#if view.template}
						<DocumentViewTemplate
							template={view.template}
							document={doc}
							driver={data.driver}
							{def}
							onreferenceclick={api.openReference}
							{historyHref}
						/>
					{:else}
						<!-- Fallback (no view template): one row per stored field, dispatched
						     through the shared typed-value renderer so money, period, and
						     dateperiod values render instead of being dropped (B-102). The
						     driver routes reference values through Capsule so they show the
						     target's display name, not the raw id token (B-132). The fallback
						     text covers the text-kind values — objects and arrays render as
						     JSON, never as `[object Object]`. -->
						<dl class="fallback-fields">
							{#each Object.entries(doc.data) as [key, value] (key)}
								{@const fd = fieldDefFor(def, key)}
								<div class="fallback-field">
									<!-- Declared title wins; humanize covers an undeclared key,
									     the same fallback the form labels use. -->
									<dt>{fd?.title ?? humanize(key)}</dt>
									<dd>
										<DvtValue
											{value}
											fieldType={fd?.type ?? null}
											fieldDef={fd}
											fallback={value == null ? '' : resolveValue(`$${key}`, doc.data)}
											driver={data.driver}
											onreferenceclick={api.openReference}
										/>
									</dd>
								</div>
							{/each}
						</dl>

						{#if fallbackChildRelations.length > 0}
							<!-- Children collections (fallback show page): read-only sections
							     fed by the same `DvtRelation` machinery the fallback form
							     renders its editable rows with. When a view template exists,
							     the template owns its own relation nodes. -->
							{#each fallbackChildRelations as rel (rel.rel)}
								<DvtRelation template={rel.node} document={doc} driver={data.driver} {def} />
							{/each}
						{/if}
					{/if}

					<!-- iam.Account credential bootstrap (invite, temporary password,
					     MFA reset). The panel self-hides when the active role holds
					     none of the relevant permissions. Known compromise: a generic
					     route names one doctype — promote to a registry or a DVT node
					     type if a second doctype ever needs feature panels. -->
					{#if qualifiedName === 'iam.Account'}
						<AccountCredentialActions
							docId={doc.meta.id}
							email={typeof doc.data.email === 'string' ? doc.data.email : null}
							status={typeof doc.data.status === 'string' ? doc.data.status : 'active'}
							serviceAccount={doc.data.service_account === true}
							onchanged={refreshDocument}
						/>
					{/if}

					<!-- Backlinks — metadata, not a relation table: the section
					     self-hides when no live document references this one. -->
					<BacklinksPanel
						driver={data.driver}
						domain={def.domain}
						docType={def.doctype}
						docId={doc.meta.id}
					/>
				</div>

				{#if sidecarEntries.length > 0}
					<aside class="sidecar-rail">
						<SidecarPanel driver={data.driver} {def} {doc} onReferenceClick={api.openReference} />
					</aside>
				{/if}
			</div>
		</div>

		<!-- Args prompt for named actions with required arguments (B-111).
		     Portalled to <body>; the menu item sets the action and opens it. -->
		<ActionArgsDialog
			bind:open={argsDialogOpen}
			action={argsAction}
			driver={data.driver}
			domain={def.domain}
			error={actionError}
			onsubmit={submitActionArgs}
		/>
	{/snippet}
</QuickViewHost>

<style>
	.doctype-show {
		position: relative;
		min-height: 100%;
		display: flex;
		flex-direction: column;
	}

	/* The page — not the panes — owns the scrollbar: the document column
	 * expands with the template and AppShell's `.main` scrolls. */
	.show-body {
		flex: 1;
		padding: 24px;
	}

	.show-content {
		max-width: 1040px;
	}

	/* ── Two-column layout when the host declares sidecars ──
	   Main column keeps today's max-width and expands with the template;
	   the rail is a fixed-width column that pins itself to the scrollport
	   with `position: sticky` and keeps its own internal scroll, so a long
	   comment thread never lengthens the page and the composer stays
	   reachable. Narrow viewports collapse to one column with the rail
	   flowing below the content and the page growing again. */
	.show-body.with-sidecars {
		display: grid;
		grid-template-columns: minmax(0, 1fr) 420px;
		gap: 24px;
	}

	.sidecar-rail {
		position: sticky;
		top: 0;
		align-self: start;
		/* Pinned at the top of `.main`'s scrollport the rail fills the
		 * visible area under the app top bar; at rest it starts below the
		 * document header, whose height is content-driven. */
		max-height: calc(100vh - var(--topbar-h));
		/* The rail never scrolls horizontally: prose wraps long tokens, and
		 * anything else that would overflow is clipped rather than widening
		 * the rail (overflow-y: auto alone would compute overflow-x to auto). */
		overflow-y: auto;
		overflow-x: hidden;
		border-left: 1px solid var(--border);
		padding-left: 20px;
	}

	@media (max-width: 1100px) {
		.show-body.with-sidecars {
			grid-template-columns: minmax(0, 1fr);
		}

		.sidecar-rail {
			position: static;
			max-height: none;
			overflow: visible;
			border-left: none;
			padding-left: 0;
			border-top: 1px solid var(--border);
			padding-top: 16px;
			margin-top: 8px;
		}
	}

	/* ── Fallback field grid (mirrors the QuickView fallback) ── */
	.fallback-fields {
		margin: 0;
		display: grid;
		gap: 12px;
		max-width: 720px;
	}

	.fallback-field dt {
		font-size: 11px;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: var(--text-3);
		font-weight: 600;
		margin-bottom: 2px;
	}

	.fallback-field dd {
		margin: 0;
		font-size: 14px;
		color: var(--text);
		font-family: var(--font-mono);
		word-break: break-word;
	}
</style>

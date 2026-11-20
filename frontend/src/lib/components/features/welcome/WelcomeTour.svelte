<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { Dialog } from 'bits-ui';
	import * as m from '$lib/paraglide/messages';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import IconButton from '$lib/components/primitives/actions/IconButton.svelte';
	import WelcomeArtPitch from './WelcomeArtPitch.svelte';
	import WelcomeArtDomains from './WelcomeArtDomains.svelte';
	import WelcomeArtBuilder from './WelcomeArtBuilder.svelte';
	import WelcomeArtAccess from './WelcomeArtAccess.svelte';
	import WelcomeArtAudit from './WelcomeArtAudit.svelte';
	import WelcomeArtIntegrate from './WelcomeArtIntegrate.svelte';
	import WelcomeArtStart from './WelcomeArtStart.svelte';
	import { getActiveRole } from '$lib/role.svelte';
	import { getShowWelcome, saveShowWelcome } from '$lib/settings.svelte';

	/**
	 * WelcomeTour — the first-run popup for admins. Mounted once in the
	 * root layout next to
	 * `NotificationPanelHost`; it opens on app load when the account's active
	 * role is the seeded admin role and the `core.show_welcome` flag is
	 * `true`. Seven steps position the product (a governance layer) and drive
	 * the first action: create a domain or import a bundle. Steps with an
	 * entry in {@link stepArt} show an illustration above the title.
	 *
	 * Dismissal contract: the "Don't show again" checkbox writes the flag
	 * through {@link onShowWelcomeWrite} (checked writes `false`, unchecking
	 * restores `true`) and the popup stays open — the checkbox never closes
	 * it: the open gate latches the load-time decision (`sessionOpened`), so
	 * the write's store flip cannot close the popup through reactivity. The
	 * close intents are the close (`&times;`) button, `Esc`, the
	 * overlay click, and the final-step Done button. A close at the final
	 * step is a completed tour: the flag writes `false`, so the popup does
	 * not re-open at the next load. A close on an earlier step is
	 * session-only — the flag keeps its value, so the popup shows again on
	 * the next load unless the checkbox already wrote `false`. A failed
	 * write keeps the popup open, shows an error, and reverts the checkbox;
	 * a CTA does not navigate.
	 *
	 * The dialog has one open value: the mount gate and the Bits UI open prop
	 * read the same `open` value, so the overlay and the content show and hide
	 * together. The dialog is a fixed frame — the width is `min(480px, 92vw)`
	 * and the height is `min(500px, 90vh)`, with the body as the flexible
	 * middle — so the art, the title, and the footer hold their positions
	 * across steps and the Next button does not move. A step change remounts
	 * the step content inside a `{#key}` block, and a CSS keyframe slides it
	 * in with a short directional move (forward on Next, back on Back); the
	 * footer, the dots, and the error stay put. The slide carries no opacity
	 * fade — the story plays assert the new step visible right after the
	 * click, and jest-dom counts a zero-opacity ancestor as invisible. The
	 * art keeps its own fade-in. The global `prefers-reduced-motion` guard in
	 * `base.css` stops the animation, so the swap is instant. Bits UI does
	 * not close the dialog on its own — the `Esc`
	 * keydown and the click outside are caught before Bits UI acts, and their
	 * close intent goes through {@link handleCloseIntent}. The dialog markup
	 * sits in a `{#key}` block keyed by the route id, so a route change
	 * rebuilds it and no old overlay can stay in the page and block clicks.
	 *
	 * The scrim passes clicks through. Bits UI forces inline
	 * `pointer-events: auto` on the overlay and locks `pointer-events` on
	 * `body` while a modal dialog is open — either one swallows the first
	 * click on the page under the tour. The `!important` rule on the overlay
	 * class and `preventScroll={false}` on the content (the supported opt-out
	 * of the body lock) free the page, so an outside click closes the tour
	 * AND reaches its target. The dialog stays modal in the ARIA and focus
	 * senses: `aria-modal`, the focus trap, and `Esc` keep working.
	 */

	let {
		/** Active role id; defaults to the session store. */
		activeRole = undefined as string | null | undefined,
		/** The `core.show_welcome` flag; defaults to the settings store. */
		showWelcome = undefined as boolean | null | undefined,
		/**
		 * Injectable flag write for `core.show_welcome` — the checkbox writes
		 * its new value (checked writes `false`), and the final-step CTA and
		 * close write `false`; stories pass a spy so no network call runs.
		 */
		onShowWelcomeWrite = saveShowWelcome,
		/** Injected navigation — the app wires `goto`, stories a spy. */
		onNavigate
	}: {
		activeRole?: string | null;
		showWelcome?: boolean | null;
		onShowWelcomeWrite?: (v: boolean) => Promise<void>;
		onNavigate: (target: 'create' | 'import') => void;
	} = $props();

	const steps = [
		{ title: m.welcome_pitch_title(), body: m.welcome_pitch_body() },
		{ title: m.welcome_domains_title(), body: m.welcome_domains_body() },
		{ title: m.welcome_builder_title(), body: m.welcome_builder_body() },
		{ title: m.welcome_access_title(), body: m.welcome_access_body() },
		{ title: m.welcome_audit_title(), body: m.welcome_audit_body() },
		{ title: m.welcome_integrate_title(), body: m.welcome_integrate_body() },
		{ title: m.welcome_start_title(), body: m.welcome_start_body() }
	];

	const lastStep = steps.length - 1;

	// Illustration per step, indexed by step number. A step without an
	// entry shows no art.
	const stepArt = [
		WelcomeArtPitch,
		WelcomeArtDomains,
		WelcomeArtBuilder,
		WelcomeArtAccess,
		WelcomeArtAudit,
		WelcomeArtIntegrate,
		WelcomeArtStart
	];

	// D3: exact id match on the seeded admin role — a bespoke admin-equivalent
	// role does not match, and the `*` wildcard permission is not consulted.
	const isAdmin = $derived((activeRole ?? getActiveRole()) === 'iam.Roles.admin');
	// `null` (store not loaded yet) never opens the tour; an explicit prop
	// wins over the store so stories can drive the gate.
	const flagOn = $derived(
		showWelcome !== undefined ? showWelcome === true : getShowWelcome() === true
	);

	// The gate passes and the tour has not been closed this session. `dismissed`
	// makes the close button / Esc / overlay close session-only: the flag keeps
	// its value, but the popup does not re-open until the next app load.
	let dismissed = $state(false);
	/**
	 * The load-time open decision, latched. The flag decides whether the tour
	 * OPENS; once it has, the session owns the popup. Every flag write (the
	 * dismiss checkbox, the final-step close, the CTAs) flips the live value
	 * the `showWelcome` prop mirrors — without the latch that flip would close
	 * the popup through reactivity before any handler continuation runs. A
	 * latch cannot be a `$derived`, so the effect records the first gate pass;
	 * it writes only `sessionOpened` and never reads it, so it does not
	 * re-trigger itself.
	 */
	let sessionOpened = $state(false);

	$effect(() => {
		if (isAdmin && flagOn) sessionOpened = true;
	});

	let step = $state(0);
	// Slide direction of the step transition — forward on Next, back on Back.
	let direction = $state<'forward' | 'back'>('forward');
	let saving = $state(false);
	let saveError = $state<string | undefined>(undefined);
	let dontShowChecked = $state(false);

	const open = $derived(isAdmin && !dismissed && (flagOn || sessionOpened));

	function goBack() {
		if (step > 0) {
			direction = 'back';
			step -= 1;
		}
	}

	function goNext() {
		if (step < lastStep) {
			direction = 'forward';
			step += 1;
		}
	}

	/**
	 * Writes the flag value through the injected callback. Returns `true`
	 * when the write landed (the CTA navigates and the final-step close
	 * dismisses only then). On failure the error shows and the popup stays
	 * open.
	 */
	async function writeFlag(value: boolean): Promise<boolean> {
		saving = true;
		saveError = undefined;
		try {
			await onShowWelcomeWrite(value);
			return true;
		} catch {
			saveError = m.welcome_save_error();
			return false;
		} finally {
			saving = false;
		}
	}

	/**
	 * The checkbox writes its new value (checked = "don't show" = `false`)
	 * and never closes the popup: the write flips the live flag the open
	 * gate reads, but the session latch holds — the popup stays mounted. A
	 * failed write reverts the toggle and shows the error.
	 */
	async function handleDontShowChange() {
		if (saving) return;
		const flagValue = !dontShowChecked;
		if (await writeFlag(flagValue)) {
			return;
		}
		dontShowChecked = flagValue;
	}

	async function handleNavigate(target: 'create' | 'import') {
		if (saving) return;
		// Write first, then navigate — the CTA does not navigate on a failed
		// save, and a landed write closes the popup.
		if (await writeFlag(false)) {
			dismissed = true;
			onNavigate(target);
		}
	}

	/**
	 * The close-intent handlers (the close button, the `Esc` keydown, the
	 * click outside, the final-step Done button) call this. Bits UI never
	 * closes the dialog on its own, so the `open` value stays the one source
	 * of truth. Closing at the final step is a completed tour: the flag is
	 * written off, so the popup does not re-open at the next load. An earlier
	 * exit closes for the session only.
	 */
	async function handleCloseIntent() {
		if (saving) return;
		if (step >= lastStep) {
			if (await writeFlag(false)) dismissed = true;
			return;
		}
		dismissed = true;
	}
</script>

<!-- One open value drives everything: the mount gate and the Bits UI open
	prop read the same `open` derivation, so the overlay and the content
	show and hide together. The route id keys the block, so a route change
	rebuilds the dialog and an old instance cannot stay in the page. -->
{#key page.route.id}
	{#if open}
		<Dialog.Root
			{open}
			onOpenChange={(v) => {
				if (!v) void handleCloseIntent();
			}}
		>
			<Dialog.Portal>
				<Dialog.Overlay class="welcome-overlay" aria-hidden="true" />
				<!-- The close intents stop here: preventDefault stops the Bits UI
					close write, and the intent goes through handleCloseIntent. A
					failed flag write then keeps the popup open, as the contract
					needs. preventDefault touches only the Bits UI close decision —
					the native click still reaches the page element under the
					pointer. That needs the scrim to pass clicks through and the
					body pointer-events lock off (preventScroll={false}); either
					lock would swallow the first outside click. -->
				<Dialog.Content
					class="welcome-content"
					preventScroll={false}
					onEscapeKeydown={(e) => {
						e.preventDefault();
						void handleCloseIntent();
					}}
					onInteractOutside={(e) => {
						e.preventDefault();
						void handleCloseIntent();
					}}
				>
					{#key step}
						<div class="welcome-step" class:welcome-step-back={direction === 'back'}>
							{#if stepArt[step]}
								{@const Art = stepArt[step]}
								<div class="welcome-art">
									<Art />
								</div>
							{/if}

							<Dialog.Title class="welcome-title">{steps[step].title}</Dialog.Title>
							<Dialog.Description class="welcome-body">{steps[step].body}</Dialog.Description>
						</div>
					{/key}

					{#if saveError}
						<p class="welcome-error" role="alert">{saveError}</p>
					{/if}

					<div class="welcome-footer">
						<div class="welcome-dots" aria-hidden="true">
							{#each steps as _, i (i)}
								<span class="welcome-dot" class:welcome-dot-active={i === step}></span>
							{/each}
						</div>
						<div class="welcome-actions">
							<label class="welcome-dismiss">
								<input
									type="checkbox"
									bind:checked={dontShowChecked}
									onchange={handleDontShowChange}
									disabled={saving}
								/>
								{m.welcome_dont_show_again()}
							</label>
							{#if step > 0 && step < lastStep}
								<Button variant="secondary" size="sm" onclick={goBack} disabled={saving}>
									{m.common_back()}
								</Button>
							{/if}
							{#if step < lastStep}
								<Button variant="primary" size="sm" onclick={goNext}>{m.welcome_next()}</Button>
							{:else}
								<!-- The final step swaps Back/Next for the two CTAs: the close
									of the tour is the action (primary "Create a domain",
									secondary "Import a bundle", D4 option A). The ghost
									"Done" is the terminal affordance for a reader who
									wants neither — it runs the same close intent as Esc
									and the close button. -->
								<Button
									variant="ghost"
									size="sm"
									onclick={() => void handleCloseIntent()}
									disabled={saving}
								>
									{m.welcome_done()}
								</Button>
								<Button
									variant="secondary"
									size="sm"
									onclick={() => handleNavigate('import')}
									disabled={saving}
								>
									{m.welcome_cta_import()}
								</Button>
								<Button
									variant="primary"
									size="sm"
									onclick={() => handleNavigate('create')}
									disabled={saving}
								>
									{m.welcome_cta_create()}
								</Button>
							{/if}
						</div>
					</div>

					<!-- The close button runs the same close intent as Esc: session-only
						on an earlier step, a completed tour (flag write) at the final one.
						It sits last in the focus order; the corner placement is visual. -->
					<IconButton
						label={m.common_close()}
						onclick={() => void handleCloseIntent()}
						disabled={saving}
						class="welcome-close"
					>
						<span class="welcome-close-x" aria-hidden="true">&times;</span>
					</IconButton>
				</Dialog.Content>
			</Dialog.Portal>
		</Dialog.Root>
	{/if}
{/key}

<style>
	:global(.welcome-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 130;
		/* Bits UI sets inline `pointer-events: auto` on the overlay, which a
		   normal rule cannot beat. The scrim must not intercept clicks — the
		   click under the pointer belongs to the page. */
		pointer-events: none !important;
	}

	:global(.welcome-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(480px, 92vw);
		/* Fixed frame: every step renders in the same box, so the footer
		   (dots, checkbox, Back/Next) holds its position across steps. */
		height: min(500px, 90vh);
		display: flex;
		flex-direction: column;
		gap: 12px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		padding: 24px;
		z-index: 131;
	}

	:global(.welcome-title) {
		font-family: var(--font-display);
		font-size: 18px;
		font-weight: 600;
		margin: 0;
	}

	.welcome-art {
		width: 100%;
		max-width: 400px;
		margin: 0 auto;
	}

	/* The step content remounts on every step change ({#key step}), so the
	   entry animation runs once per slide. The wrapper takes over the flexible
	   middle from the body; the footer below it stays still. The duration and
	   easing match the welcome art's own motion. Transform only — a zero
	   opacity start would fail the play functions' immediate toBeVisible
	   asserts (jest-dom counts zero-opacity ancestors as invisible). */
	.welcome-step {
		display: flex;
		flex-direction: column;
		gap: 12px;
		flex: 1;
		min-height: 0;
		animation: welcome-step-in 0.35s cubic-bezier(0.2, 0.8, 0.2, 1) both;
	}

	.welcome-step-back {
		animation-name: welcome-step-in-back;
	}

	@keyframes welcome-step-in {
		from {
			transform: translateX(12px);
		}
		to {
			transform: none;
		}
	}

	@keyframes welcome-step-in-back {
		from {
			transform: translateX(-12px);
		}
		to {
			transform: none;
		}
	}

	:global(.welcome-body) {
		font-size: 13.5px;
		color: var(--text-2);
		line-height: 1.55;
		margin: 0;
		/* The flexible middle: it absorbs the height variance between steps
		   (body length, the error row, the wrapped final-step footer), so the
		   footer stays pinned to the bottom edge. */
		flex: 1;
		min-height: 0;
		overflow-y: auto;
	}

	.welcome-error {
		font-size: 12.5px;
		color: var(--danger);
		margin: 0;
		padding: 8px 10px;
		background: var(--danger-weak, rgba(220, 38, 38, 0.08));
		border-radius: var(--r);
	}

	.welcome-footer {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 12px;
		margin-top: 8px;
	}

	.welcome-dots {
		display: flex;
		align-items: center;
		gap: 6px;
		margin-right: auto;
	}

	.welcome-dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--border-strong);
		transition: background 0.15s;
	}

	.welcome-dot-active {
		background: var(--accent);
	}

	.welcome-dismiss {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		font-size: 12.5px;
		color: var(--text-2);
		cursor: pointer;
		user-select: none;
	}

	.welcome-dismiss input {
		accent-color: var(--accent);
		cursor: pointer;
	}

	.welcome-actions {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	/* The close button lives inside the portalled Dialog.Content, so the
	   placement rule must be global; the glyph span is component-owned. */
	:global(.welcome-close) {
		position: absolute;
		top: 10px;
		right: 10px;
	}

	.welcome-close-x {
		display: block;
		font-size: 20px;
		line-height: 1;
	}
</style>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { page } from '$app/state';
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import WelcomeTour from './WelcomeTour.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Welcome/WelcomeTour',
		component: WelcomeTour,
		tags: ['autodocs'],
		argTypes: {
			// The spies are play-internal concerns; the controls pane stays
			// focused on the observable surface (role + flag).
			onShowWelcomeWrite: { table: { disable: true } },
			onNavigate: { table: { disable: true } }
		}
	});

	// ── Spies ──────────────────────────────────────────────────────
	// Stories run sequentially in one iframe; each play resets the shared
	// spies before driving the component. `saveShouldFail` simulates a
	// rejected `core.show_welcome` write.
	let saveCalls: boolean[] = [];
	let navigations: Array<'create' | 'import'> = [];
	let saveShouldFail = false;
	let outsideClicks = 0;
	/**
	 * The live `core.show_welcome` value, as the layout passes it: a tracked
	 * read rendered into the `showWelcome` prop. `storeWriteSpy` flips it the
	 * way `saveShowWelcome` flips the real store, so a story can exercise the
	 * gate against a write that changes the reactive source it reads.
	 */
	let liveFlag = $state<boolean | null>(true);

	async function saveSpy(v: boolean): Promise<void> {
		saveCalls.push(v);
		if (saveShouldFail) throw new Error('save failed');
	}

	async function storeWriteSpy(v: boolean): Promise<void> {
		saveCalls.push(v);
		if (saveShouldFail) throw new Error('save failed');
		liveFlag = v;
	}

	function navigateSpy(target: 'create' | 'import'): void {
		navigations.push(target);
	}

	function resetSpies(options?: { fail?: boolean }) {
		saveCalls = [];
		navigations = [];
		saveShouldFail = options?.fail ?? false;
		outsideClicks = 0;
		liveFlag = true;
	}

	/** Base gate args: an admin with the flag on. */
	const adminArgs = { activeRole: 'iam.Roles.admin', showWelcome: true };
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
</script>

<!--
	The dialog portals into `document.body`, so the play functions query
	`within(document.body)`. Both injected callbacks are spies: no network
	call and no navigation run in stories. The welcome dialog opts out of
	the Bits UI body lock (`preventScroll={false}`), so its open/close never
	puts `pointer-events: none` on `<body>`; other stories' modals can, and
	the global loader in preview.ts waits that out before each story.
-->

<Story
	name="StepsAdvanceAndGoBack"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		await userEvent.click(body.getByRole('button', { name: 'Next' }));
		await expect(body.getByText('Start with a domain')).toBeVisible();

		await userEvent.click(body.getByRole('button', { name: 'Back' }));
		await expect(body.getByText('A governance layer')).toBeVisible();

		// No writes happened — stepping never touches the flag.
		await expect(saveCalls).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FinalStepShowsBothCtas"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		// Step through all seven steps.
		for (let i = 0; i < 6; i += 1) {
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
		}
		await expect(body.getByText('Your first domain')).toBeVisible();

		// The close of the tour is the action: two CTAs plus the terminal Done,
		// and no Next.
		await expect(body.getByRole('button', { name: 'Create a domain' })).toBeVisible();
		await expect(body.getByRole('button', { name: 'Import a bundle' })).toBeVisible();
		await expect(body.getByRole('button', { name: 'Done' })).toBeVisible();
		await expect(body.queryByRole('button', { name: 'Next' })).toBeNull();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CreateCtaSavesThenNavigates"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());
		for (let i = 0; i < 6; i += 1) {
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
		}

		await userEvent.click(body.getByRole('button', { name: 'Create a domain' }));

		// The write lands first, then the navigation, then the popup closes.
		await waitFor(() => expect(saveCalls).toEqual([false]));
		await waitFor(() => expect(navigations).toEqual(['create']));
		await waitFor(() => expect(body.queryByText('Your first domain')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ImportCtaSavesThenNavigates"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());
		for (let i = 0; i < 6; i += 1) {
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
		}

		await userEvent.click(body.getByRole('button', { name: 'Import a bundle' }));

		await waitFor(() => expect(saveCalls).toEqual([false]));
		await waitFor(() => expect(navigations).toEqual(['import']));
		await waitFor(() => expect(body.queryByText('Your first domain')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<!--
	The terminal Done button runs the same close intent as Esc and the close
	button at the final step: the flag is written off, the popup closes, and
	no CTA navigates.
-->
<Story
	name="FinalStepDoneWritesOffAndCloses"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());
		for (let i = 0; i < 6; i += 1) {
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
		}
		await expect(body.getByText('Your first domain')).toBeVisible();

		await userEvent.click(body.getByRole('button', { name: 'Done' }));

		await waitFor(() => expect(saveCalls).toEqual([false]));
		await waitFor(() => expect(body.queryByText('Your first domain')).toBeNull());
		await expect(navigations).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FailedSaveKeepsTheTourOpen"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies({ fail: true });
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());
		for (let i = 0; i < 6; i += 1) {
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
		}

		await userEvent.click(body.getByRole('button', { name: 'Create a domain' }));

		// The write failed: the error shows, the popup stays open, and the
		// CTA does not navigate.
		await waitFor(() => expect(body.getByText(/Could not save the setting/)).toBeVisible());
		await expect(body.getByText('Your first domain')).toBeVisible();
		await expect(navigations).toEqual([]);
		await expect(saveCalls).toEqual([false]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CheckboxWritesFlagAndStaysOpen"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		// Checking writes `false` — and the popup stays open.
		await userEvent.click(body.getByLabelText("Don't show again"));
		await waitFor(() => expect(saveCalls).toEqual([false]));
		await expect(body.getByText('A governance layer')).toBeVisible();
		await expect(navigations).toEqual([]);

		// Unchecking restores `true` — still no close.
		await userEvent.click(body.getByLabelText("Don't show again"));
		await waitFor(() => expect(saveCalls).toEqual([false, true]));
		await expect(body.getByText('A governance layer')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CheckboxWriteFlipsStoreKeepsPopupMounted"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		// The real wiring: the write flips the live store, and the layout
		// re-renders the `showWelcome` prop — the reactive source the open
		// gate reads. The popup must survive that flip as the same element:
		// no close, no unmount, no remount.
		const before = document.querySelector('.welcome-content');
		await userEvent.click(body.getByLabelText("Don't show again"));
		await waitFor(() => expect(saveCalls).toEqual([false]));
		await waitFor(() => expect(liveFlag).toBe(false));
		await expect(body.getByText('A governance layer')).toBeVisible();

		// Let every pending flush land, then re-check the element identity.
		await new Promise((r) => setTimeout(r, 50));
		const after = document.querySelector('.welcome-content');
		expect(after).toBe(before);
		await expect(body.getByLabelText("Don't show again")).toBeChecked();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={liveFlag}
				onShowWelcomeWrite={storeWriteSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FailedCheckboxWriteRevertsAndStaysOpen"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies({ fail: true });
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		// The write failed: the checkbox reverts to unchecked, the error
		// shows, and the popup stays open.
		await userEvent.click(body.getByLabelText("Don't show again"));
		await waitFor(() => expect(saveCalls).toEqual([false]));
		await expect(body.getByLabelText("Don't show again")).not.toBeChecked();
		await expect(body.getByText(/Could not save the setting/)).toBeVisible();
		await expect(body.getByText('A governance layer')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FinalStepEscapeWritesOff"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());
		for (let i = 0; i < 6; i += 1) {
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
		}
		await expect(body.getByText('Your first domain')).toBeVisible();

		// Esc at the final step is a completed tour: the flag is written off.
		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(saveCalls).toEqual([false]));
		await waitFor(() => expect(body.queryByText('Your first domain')).toBeNull());
		await expect(navigations).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EarlyEscapeIsSessionOnly"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		// The overlay is decoration: assistive tech and tooling ignore it.
		expect(body.getByText('A governance layer')).toBeVisible();
		await expect(document.querySelector('.welcome-overlay')).toHaveAttribute('aria-hidden', 'true');

		// Esc on an earlier step closes for the session only — no write.
		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByText('A governance layer')).toBeNull());
		await expect(saveCalls).toEqual([]);
		await expect(navigations).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CloseButtonIsSessionOnly"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		// The close button on an earlier step is session-only: no flag write.
		await userEvent.click(body.getByRole('button', { name: 'Close' }));
		await waitFor(() => expect(body.queryByText('A governance layer')).toBeNull());
		await expect(saveCalls).toEqual([]);
		await expect(navigations).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FinalStepCloseButtonWritesOff"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());
		for (let i = 0; i < 6; i += 1) {
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
		}
		await expect(body.getByText('Your first domain')).toBeVisible();

		// The close button at the final step is a completed tour: the flag
		// is written off and the popup closes.
		await userEvent.click(body.getByRole('button', { name: 'Close' }));
		await waitFor(() => expect(saveCalls).toEqual([false]));
		await waitFor(() => expect(body.queryByText('Your first domain')).toBeNull());
		await expect(navigations).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="OutsideClickClosesTourAndReachesTarget"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		// The scrim passes clicks through: Bits UI forces inline
		// `pointer-events: auto` on the overlay, and the component overrides
		// it, so the overlay never intercepts. The body lock is off too, so
		// the page under the tour is clickable.
		const overlay = document.querySelector('.welcome-overlay') as HTMLElement;
		await expect(getComputedStyle(overlay).pointerEvents).toBe('none');
		await expect(document.body.style.pointerEvents).not.toBe('none');

		// One click closes the tour AND reaches the page element under the
		// pointer — the first navigation click is not swallowed.
		await userEvent.click(body.getByRole('button', { name: 'Page button' }));
		await waitFor(() => expect(body.queryByText('A governance layer')).toBeNull());
		await expect(outsideClicks).toBe(1);
		// An early-step close is session-only: no flag write, no navigation.
		await expect(saveCalls).toEqual([]);
		await expect(navigations).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<button type="button" onclick={() => (outsideClicks += 1)}>Page button</button>
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="NonAdminRoleRendersNothing"
	args={{ activeRole: 'iam.Roles.editor', showWelcome: true }}
	play={async ({ canvasElement }) => {
		resetSpies();
		const body = within(document.body);

		// The role gate fails — no tour in the canvas and nothing in the portal.
		await new Promise((r) => setTimeout(r, 100));
		await expect(within(canvasElement).queryByText('A governance layer')).toBeNull();
		await expect(body.queryByText('A governance layer')).toBeNull();
		await expect(saveCalls).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CloseThenRouteChangeLeavesNoOverlay"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());
		await expect(document.querySelector('.welcome-overlay')).toHaveAttribute('data-state', 'open');

		// Esc on an early step closes for the session: the overlay leaves the DOM.
		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(document.querySelector('.welcome-overlay')).toBeNull());
		await waitFor(() => expect(document.body.style.pointerEvents).not.toBe('none'));

		// A route change rebuilds the keyed dialog block. The tour stays closed
		// for the session, and no overlay element may stay behind to catch clicks.
		// The mock page state is shared across stories: the reset sits in a
		// `finally` so a failed assertion above cannot leave `page.route` on
		// '/' for the rest of the suite.
		try {
			page.route = { id: '/' };
			await new Promise((r) => setTimeout(r, 100));
			expect(document.querySelector('.welcome-overlay')).toBeNull();
			expect(document.querySelector('.welcome-content')).toBeNull();
			expect(document.body.style.pointerEvents).not.toBe('none');
		} finally {
			page.route = { id: null };
		}
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="RouteChangeMidTourKeepsOneOverlay"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());

		// A route change mid-tour rebuilds the dialog: exactly one overlay may
		// remain, and the tour must stay open at the same step. The mock page
		// state is shared across stories: the reset sits in a `finally` so a
		// failed assertion cannot leave `page.route` on '/' for the suite.
		try {
			page.route = { id: '/' };
			await waitFor(() => expect(document.querySelectorAll('.welcome-overlay').length).toBe(1));
			await expect(body.getByText('A governance layer')).toBeVisible();

			// The rebuilt dialog is interactive; Esc then closes it for the session.
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
			await userEvent.keyboard('{Escape}');
			await waitFor(() => expect(document.querySelector('.welcome-overlay')).toBeNull());
			await waitFor(() => expect(document.body.style.pointerEvents).not.toBe('none'));
			await expect(saveCalls).toEqual([]);
		} finally {
			page.route = { id: null };
		}
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FinalStepEscapeWithFailedWriteStaysOpen"
	args={{ ...adminArgs }}
	play={async () => {
		resetSpies({ fail: true });
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('A governance layer')).toBeVisible());
		for (let i = 0; i < 6; i += 1) {
			await userEvent.click(body.getByRole('button', { name: 'Next' }));
		}
		await expect(body.getByText('Your first domain')).toBeVisible();

		// Esc at the final step starts the flag write. A failed write keeps the
		// popup open and shows the error — the dialog must not disappear.
		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(saveCalls).toEqual([false]));
		await expect(body.getByText('Your first domain')).toBeVisible();
		await expect(body.getByText(/Could not save the setting/)).toBeVisible();
		await expect(navigations).toEqual([]);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px;">
			<WelcomeTour
				activeRole={args.activeRole}
				showWelcome={args.showWelcome}
				onShowWelcomeWrite={saveSpy}
				onNavigate={navigateSpy}
			/>
		</div>
	{/snippet}
</Story>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import type { LayoutData } from './$types';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Wizard shell — owns the thin horizontal stepper shown above each
	 * step's content. The Back/Continue footer and per-step form logic
	 * live in the step pages themselves so each step owns its mutations.
	 *
	 * The shell is URL-driven: the current step is the last URL segment
	 * (setup / permissions / review / credentials). The in-progress
	 * document id threads through the `?app=<id>` query parameter, which
	 * the setup step's create appends with `replaceState` so it does not
	 * pollute history.
	 *
	 * The stepper is a single inline row — `step-number + label` separated
	 * by chevrons. The active step is filled; future steps are muted.
	 * Clicking a future step is disabled unless `data.app` exists.
	 */

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	const steps = [
		{ key: 'setup', label: m.configure_apps_wizard_setup() },
		{ key: 'permissions', label: m.configure_apps_wizard_permissions() },
		{ key: 'review', label: m.configure_apps_wizard_review() },
		{ key: 'credentials', label: m.configure_apps_wizard_credentials() }
	] as const;

	const currentIndex = $derived(steps.findIndex((s) => s.key === data.step));

	function gotoStep(step: (typeof steps)[number]['key']): void {
		const search = data.app ? `?app=${data.app.meta.id}` : '';
		goto(resolve(`/Configure/apps/new/${step}${search}`));
	}
</script>

<div class="wizard">
	<nav class="stepper" aria-label={m.configure_apps_wizard_aria()}>
		{#each steps as step, i (step.key)}
			<button
				type="button"
				class="step"
				class:step-active={i === currentIndex}
				class:step-done={i < currentIndex}
				disabled={i > currentIndex && !data.app}
				onclick={() => gotoStep(step.key)}
			>
				<span class="step-num" aria-hidden="true">{i + 1}</span>
				<span class="step-label">{step.label}</span>
			</button>
			{#if i < steps.length - 1}
				<span class="step-sep" aria-hidden="true">›</span>
			{/if}
		{/each}
	</nav>

	<div class="step-content">
		{@render children?.()}
	</div>
</div>

<style>
	.wizard {
		padding: 28px 32px 48px;
		max-width: 880px;
		margin: 0 auto;
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	.stepper {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
		/* Contain the rail in a surface and centre it at the top of the wizard
		   so it reads as a deliberately-aligned header above the step card. */
		align-self: center;
		padding: 6px 14px;
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-pill, 999px);
	}

	.step {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		background: transparent;
		border: none;
		padding: 4px 2px;
		cursor: pointer;
		font: inherit;
		color: var(--text-3);
		transition: color 0.12s;
	}

	.step:hover:not(:disabled) {
		color: var(--text-2);
	}

	.step:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.step-active {
		color: var(--text);
		font-weight: 500;
	}

	.step-done {
		color: var(--text-2);
	}

	.step-num {
		flex: none;
		width: 20px;
		height: 20px;
		border-radius: 50%;
		background: var(--surface-2);
		border: 1px solid var(--border);
		color: var(--text-3);
		font-size: 11px;
		font-weight: 600;
		display: inline-flex;
		align-items: center;
		justify-content: center;
	}

	.step-active .step-num {
		background: var(--accent);
		border-color: var(--accent);
		color: var(--on-accent);
	}

	.step-done .step-num {
		background: var(--accent-weak);
		border-color: var(--accent);
		color: var(--accent);
	}

	.step-label {
		font-size: 13px;
	}

	.step-sep {
		color: var(--text-3);
		font-size: 13px;
		user-select: none;
	}

	.step-content {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}
</style>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	/**
	 * WelcomeArtAccess — the illustration for the fourth step of the welcome
	 * tour. A role list (Manager, Sales rep, Auditor) sits next to a doctype
	 * panel with CRUD toggles. The selection starts on Manager, then moves to
	 * Sales rep: U and D switch off, a column masks over (field level), and a
	 * veil plus lock pills cover the rows outside the scope (row level).
	 *
	 * The colours come from the design tokens, so the art follows the theme
	 * of the dialog surface. The `prefers-reduced-motion` guard in `base.css`
	 * stops every animation; the transient overlays (the U/D on-state) then
	 * keep their base `opacity: 0`, and the restricted Sales-rep state shows.
	 *
	 * The avatar and lock shapes are inlined at each position (no `<defs>` +
	 * `<use>`): a `<use>` shadow tree cannot be reached by the component's
	 * scoped CSS, so the token classes would not apply to the clones. The
	 * hatch `<pattern>` stays in `<defs>` — a pattern cannot be inlined —
	 * under a component-specific id to avoid collisions.
	 */
</script>

<svg viewBox="0 0 400 200" role="img" aria-labelledby="welcome-art-access-title">
	<title id="welcome-art-access-title">{m.welcome_access_art_aria()}</title>

	<defs>
		<pattern
			id="welcome-art-access-hatch"
			width="6"
			height="6"
			patternUnits="userSpaceOnUse"
			patternTransform="rotate(45)"
		>
			<rect class="hatch-bg" width="6" height="6" />
			<line class="hatch-line" x1="0" y1="0" x2="0" y2="6" />
		</pattern>
	</defs>

	<!-- Roles -->
	<g class="select">
		<rect class="select-box" x="16" y="83" width="122" height="34" rx="8" />
		<line class="select-line" x1="138" y1="100" x2="152" y2="100" />
	</g>

	<g class="pop ro1">
		<circle class="avatar-manager" cx="38" cy="62" r="11" />
		<g class="person" transform="translate(38 62)">
			<circle cx="0" cy="-2.5" r="3.6" />
			<path d="M-6.5 7 a6.5 5.5 0 0 1 13 0 Z" />
		</g>
		<text class="role" x="56" y="65.5">{m.welcome_access_art_manager()}</text>
	</g>
	<g class="pop ro2">
		<circle class="avatar-sales" cx="38" cy="100" r="11" />
		<g class="person" transform="translate(38 100)">
			<circle cx="0" cy="-2.5" r="3.6" />
			<path d="M-6.5 7 a6.5 5.5 0 0 1 13 0 Z" />
		</g>
		<text class="role" x="56" y="103.5">{m.welcome_access_art_sales_rep()}</text>
	</g>
	<g class="pop ro3">
		<circle class="avatar-auditor" cx="38" cy="138" r="11" />
		<g class="person" transform="translate(38 138)">
			<circle cx="0" cy="-2.5" r="3.6" />
			<path d="M-6.5 7 a6.5 5.5 0 0 1 13 0 Z" />
		</g>
		<text class="role" x="56" y="141.5">{m.welcome_access_art_auditor()}</text>
	</g>

	<!-- Doctype panel -->
	<g class="fade panel">
		<rect class="card" x="152" y="30" width="232" height="140" rx="10" />
		<rect class="chip-a" x="164" y="40" width="22" height="8" rx="4" />
		<rect class="head" x="192" y="42" width="40" height="4" rx="2" />
		<line class="divider" x1="152" y1="58" x2="384" y2="58" />

		<!-- CRUD toggles, off state (base) -->
		<g class="crud" text-anchor="middle">
			<rect class="crud-box-off" x="290" y="36" width="18" height="16" rx="4" />
			<text class="crud-off" x="299" y="47">R</text>
			<rect class="crud-box-off" x="312" y="36" width="18" height="16" rx="4" />
			<text class="crud-off" x="321" y="47">C</text>
			<rect class="crud-box-off" x="334" y="36" width="18" height="16" rx="4" />
			<text class="crud-off" x="343" y="47">U</text>
			<rect class="crud-box-off" x="356" y="36" width="18" height="16" rx="4" />
			<text class="crud-off" x="365" y="47">D</text>
		</g>

		<!-- Column headers -->
		<rect class="head" x="164" y="66" width="30" height="4" rx="2" />
		<rect class="head" x="234" y="66" width="26" height="4" rx="2" />
		<rect class="head" x="306" y="66" width="28" height="4" rx="2" />
	</g>

	<!-- CRUD on states -->
	<g class="crud pop on-rc" text-anchor="middle">
		<rect class="crud-box-on" x="290" y="36" width="18" height="16" rx="4" />
		<text class="crud-on" x="299" y="47">R</text>
		<rect class="crud-box-on" x="312" y="36" width="18" height="16" rx="4" />
		<text class="crud-on" x="321" y="47">C</text>
	</g>
	<g class="crud on-ud" text-anchor="middle">
		<rect class="crud-box-on" x="334" y="36" width="18" height="16" rx="4" />
		<text class="crud-on" x="343" y="47">U</text>
		<rect class="crud-box-on" x="356" y="36" width="18" height="16" rx="4" />
		<text class="crud-on" x="365" y="47">D</text>
	</g>

	<!-- Rows -->
	<g class="row r1">
		<line class="rowline" x1="160" y1="78" x2="376" y2="78" />
		<rect class="line" x="164" y="86" width="46" height="4" rx="2" />
		<rect class="line" x="234" y="86" width="36" height="4" rx="2" />
		<rect class="line" x="306" y="86" width="40" height="4" rx="2" />
	</g>
	<g class="row r2">
		<line class="rowline" x1="160" y1="98" x2="376" y2="98" />
		<rect class="line" x="164" y="106" width="38" height="4" rx="2" />
		<rect class="line" x="234" y="106" width="44" height="4" rx="2" />
		<rect class="line" x="306" y="106" width="30" height="4" rx="2" />
	</g>
	<g class="row r3">
		<line class="rowline" x1="160" y1="118" x2="376" y2="118" />
		<rect class="line" x="164" y="126" width="50" height="4" rx="2" />
		<rect class="line" x="234" y="126" width="30" height="4" rx="2" />
		<rect class="line" x="306" y="126" width="44" height="4" rx="2" />
	</g>
	<g class="row r4">
		<line class="rowline" x1="160" y1="138" x2="376" y2="138" />
		<rect class="line" x="164" y="146" width="42" height="4" rx="2" />
		<rect class="line" x="234" y="146" width="40" height="4" rx="2" />
		<rect class="line" x="306" y="146" width="36" height="4" rx="2" />
	</g>

	<!-- Field level: the masked column -->
	<g class="mask">
		<rect x="300" y="62" width="76" height="98" rx="5" fill="url(#welcome-art-access-hatch)" />
		<rect class="mask-edge" x="300" y="62" width="76" height="98" rx="5" />
	</g>
	<g class="pop lk1">
		<circle class="lock-badge" cx="338" cy="111" r="9" />
		<g transform="translate(338 111.5)">
			<path class="lock-shackle" d="M-2.6 -1 v-2.2 a2.6 2.6 0 0 1 5.2 0 V-1" />
			<rect class="lock-body" x="-4" y="-1.5" width="8" height="6.5" rx="1.5" />
		</g>
	</g>

	<!-- Row level: the rows outside the scope -->
	<rect class="row-veil rowlock" x="158" y="119" width="140" height="39" />
	<g class="pop lk2">
		<rect class="lock-badge" x="214" y="130" width="28" height="16" rx="8" />
		<g transform="translate(228 138.5)">
			<path class="lock-shackle" d="M-2.6 -1 v-2.2 a2.6 2.6 0 0 1 5.2 0 V-1" />
			<rect class="lock-body" x="-4" y="-1.5" width="8" height="6.5" rx="1.5" />
		</g>
	</g>
</svg>

<style>
	svg {
		display: block;
		width: 100%;
		height: auto;
	}

	/* Design tokens only — the art re-themes with the dialog surface. */
	.card {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.25;
	}
	.line {
		fill: var(--border);
	}
	.head {
		fill: var(--border-strong);
	}
	.chip-a {
		fill: var(--accent);
	}
	.divider {
		stroke: var(--border);
		stroke-width: 1.25;
	}
	.rowline {
		stroke: var(--border);
	}
	.select-box {
		fill: var(--accent-weak);
		stroke: var(--accent);
		stroke-width: 1.5;
	}
	.select-line {
		stroke: var(--accent);
		stroke-width: 1.5;
	}
	.avatar-manager {
		fill: var(--text-2);
	}
	.avatar-sales {
		fill: var(--accent);
	}
	.avatar-auditor {
		fill: var(--text-3);
	}
	.person {
		fill: var(--surface);
	}
	.role {
		font-family: var(--font-display);
		font-size: 10px;
		font-weight: 600;
		fill: var(--text);
	}
	.crud {
		font-family: var(--font-display);
		font-size: 8px;
		font-weight: 700;
	}
	.crud-box-off {
		fill: var(--sunken);
	}
	.crud-box-on {
		fill: var(--accent);
	}
	.crud-off {
		fill: var(--text-3);
	}
	.crud-on {
		fill: var(--on-accent);
	}
	.hatch-bg {
		fill: var(--sunken);
	}
	.hatch-line {
		stroke: var(--border);
		stroke-width: 2.5;
	}
	.mask-edge {
		fill: none;
		stroke: var(--border-strong);
		stroke-dasharray: 3 2;
	}
	.lock-badge {
		fill: var(--surface);
		stroke: var(--border-strong);
	}
	.lock-shackle {
		fill: none;
		stroke: var(--text-2);
		stroke-width: 1.4;
		stroke-linecap: round;
	}
	.lock-body {
		fill: var(--text-2);
	}
	.row-veil {
		fill: var(--surface);
		opacity: 0.82;
	}

	/* Base state is the final frame (Sales rep selected, restricted); the
	   full-access overlays start hidden, so a static render shows the
	   restricted state. */
	.pop {
		transform-box: fill-box;
		transform-origin: center;
		animation: pop 0.35s cubic-bezier(0.3, 1.6, 0.5, 1) both;
	}
	.fade {
		animation: fade 0.4s ease-out both;
	}
	.row {
		animation: slide 0.35s cubic-bezier(0.2, 0.8, 0.2, 1) both;
	}
	@keyframes pop {
		from {
			opacity: 0;
			transform: scale(0.5);
		}
		to {
			opacity: 1;
			transform: scale(1);
		}
	}
	@keyframes fade {
		from {
			opacity: 0;
		}
		to {
			opacity: 1;
		}
	}
	@keyframes slide {
		from {
			opacity: 0;
			transform: translateX(-8px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	.ro1 {
		animation-delay: 0s;
	}
	.ro2 {
		animation-delay: 0.1s;
	}
	.ro3 {
		animation-delay: 0.2s;
	}
	.panel {
		animation-delay: 0.25s;
	}
	.r1 {
		animation-delay: 0.45s;
	}
	.r2 {
		animation-delay: 0.55s;
	}
	.r3 {
		animation-delay: 0.65s;
	}
	.r4 {
		animation-delay: 0.75s;
	}

	/* Selection: appears on Manager, then moves to Sales rep */
	.select {
		animation: select 2.8s cubic-bezier(0.5, 0, 0.2, 1) both;
	}
	@keyframes select {
		0%,
		30% {
			opacity: 0;
			transform: translateY(-38px);
		}
		40%,
		86% {
			opacity: 1;
			transform: translateY(-38px);
		}
		100% {
			opacity: 1;
			transform: none;
		}
	}

	/* CRUD: R and C stay on; U and D are on for Manager, then switch off */
	.on-rc {
		animation-delay: 0.95s;
	}
	.on-ud {
		opacity: 0;
		animation: onud 2.9s linear both;
	}
	@keyframes onud {
		0%,
		32% {
			opacity: 0;
		}
		36%,
		90% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}

	/* Restrictions for Sales rep */
	.mask {
		animation: fade 0.45s ease-out 2.85s both;
	}
	.rowlock {
		animation: fade 0.45s ease-out 3.05s both;
	}
	.lk1 {
		animation-delay: 3s;
	}
	.lk2 {
		animation-delay: 3.25s;
	}
</style>

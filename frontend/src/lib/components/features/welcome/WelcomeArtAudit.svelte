<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	/**
	 * WelcomeArtAudit — the illustration for the fifth step of the welcome
	 * tour. A document sits next to an append-only log rail; entries land
	 * one after another (created, edited, edited), the changing field
	 * flashes as its value moves, an entry is picked, an arrow draws back to
	 * the document, and the rollback itself lands as the newest entry, with
	 * a breathing dot.
	 *
	 * The colours come from the design tokens, so the art follows the theme
	 * of the dialog surface. The `prefers-reduced-motion` guard in `base.css`
	 * stops every animation; the transient overlays (later field values,
	 * flashes, the rollback gesture) then keep their base `opacity: 0`, and
	 * the rolled-back state shows.
	 *
	 * The avatar, clock, and globe shapes are inlined at each position (no
	 * `<defs>` + `<use>`): a `<use>` shadow tree cannot be reached by the
	 * component's scoped CSS, so the token classes would not apply to the
	 * clones.
	 */
</script>

<svg viewBox="0 0 400 200" role="img" aria-labelledby="welcome-art-audit-title">
	<title id="welcome-art-audit-title">{m.welcome_audit_art_aria()}</title>

	<!-- Document -->
	<g class="fade doc">
		<rect class="card" x="22" y="36" width="126" height="128" rx="10" />
		<rect class="chip-a" x="34" y="48" width="22" height="8" rx="4" />
		<rect class="head" x="62" y="50" width="44" height="4" rx="2" />
		<line class="divider" x1="22" y1="64" x2="148" y2="64" />

		<rect class="head" x="34" y="74" width="28" height="3" rx="1.5" />
		<rect class="box" x="34" y="81" width="102" height="13" rx="3" />
		<rect class="line" x="39" y="85.5" width="54" height="4" rx="2" />

		<rect class="head" x="34" y="102" width="34" height="3" rx="1.5" />
		<rect class="box" x="34" y="109" width="102" height="13" rx="3" />
		<rect class="muted" x="39" y="113.5" width="40" height="4" rx="2" />

		<rect class="head" x="34" y="130" width="24" height="3" rx="1.5" />
		<rect class="box" x="34" y="137" width="102" height="13" rx="3" />
		<rect class="line" x="39" y="141.5" width="46" height="4" rx="2" />
	</g>
	<!-- Changing field: later states -->
	<rect class="flash" x="31" y="106" width="108" height="19" rx="5" />
	<g class="v2">
		<rect class="box" x="35" y="110" width="100" height="11" rx="2.5" />
		<rect class="chip-a" x="39" y="113.5" width="66" height="4" rx="2" />
	</g>
	<g class="v3">
		<rect class="box" x="35" y="110" width="100" height="11" rx="2.5" />
		<rect class="value-new" x="39" y="113.5" width="28" height="4" rx="2" />
	</g>

	<!-- Append-only log -->
	<line class="fade rail" x1="182" y1="46" x2="182" y2="152" />

	<!-- e1: created (v1) -->
	<g class="append e1">
		<circle class="dot" cx="182" cy="48" r="4" />
		<rect class="entry" x="194" y="34" width="186" height="28" rx="7" />
		<circle class="actor-a" cx="210" cy="48" r="7" />
		<g class="person" transform="translate(210 48)">
			<circle cx="0" cy="-1.6" r="2.4" />
			<path d="M-4.2 4.6 a4.2 3.6 0 0 1 8.4 0 Z" />
		</g>
		<rect class="head" x="223" y="41" width="38" height="4" rx="2" />
		<g transform="translate(226 53)">
			<circle class="ico-ring" r="3.2" />
			<path class="ico-hands" d="M0 -1.8 V0 H1.5" />
		</g>
		<rect class="line" x="232" y="51.5" width="16" height="3" rx="1.5" />
		<g transform="translate(256 53)">
			<circle class="ico-ring" r="3.2" />
			<ellipse class="ico-meridian" rx="1.4" ry="3.2" />
			<line class="ico-meridian" x1="-3.2" y1="0" x2="3.2" y2="0" />
		</g>
		<rect class="line" x="262" y="51.5" width="18" height="3" rx="1.5" />
		<rect class="box" x="322" y="43" width="48" height="10" rx="2.5" />
		<rect class="muted" x="326" y="46" width="20" height="4" rx="2" />
	</g>
	<!-- e2: edit (v2) -->
	<g class="append e2">
		<circle class="dot" cx="182" cy="82" r="4" />
		<rect class="entry" x="194" y="68" width="186" height="28" rx="7" />
		<circle class="actor-b" cx="210" cy="82" r="7" />
		<g class="person" transform="translate(210 82)">
			<circle cx="0" cy="-1.6" r="2.4" />
			<path d="M-4.2 4.6 a4.2 3.6 0 0 1 8.4 0 Z" />
		</g>
		<rect class="head" x="223" y="75" width="30" height="4" rx="2" />
		<g transform="translate(226 87)">
			<circle class="ico-ring" r="3.2" />
			<path class="ico-hands" d="M0 -1.8 V0 H1.5" />
		</g>
		<rect class="line" x="232" y="85.5" width="16" height="3" rx="1.5" />
		<g transform="translate(256 87)">
			<circle class="ico-ring" r="3.2" />
			<ellipse class="ico-meridian" rx="1.4" ry="3.2" />
			<line class="ico-meridian" x1="-3.2" y1="0" x2="3.2" y2="0" />
		</g>
		<rect class="line" x="262" y="85.5" width="22" height="3" rx="1.5" />
		<rect class="box" x="322" y="77" width="48" height="10" rx="2.5" />
		<rect class="chip-a" x="326" y="80" width="33" height="4" rx="2" />
	</g>
	<!-- e3: edit (v3) -->
	<g class="append e3">
		<circle class="dot" cx="182" cy="116" r="4" />
		<rect class="entry" x="194" y="102" width="186" height="28" rx="7" />
		<circle class="actor-c" cx="210" cy="116" r="7" />
		<g class="person" transform="translate(210 116)">
			<circle cx="0" cy="-1.6" r="2.4" />
			<path d="M-4.2 4.6 a4.2 3.6 0 0 1 8.4 0 Z" />
		</g>
		<rect class="head" x="223" y="109" width="42" height="4" rx="2" />
		<g transform="translate(226 121)">
			<circle class="ico-ring" r="3.2" />
			<path class="ico-hands" d="M0 -1.8 V0 H1.5" />
		</g>
		<rect class="line" x="232" y="119.5" width="16" height="3" rx="1.5" />
		<g transform="translate(256 121)">
			<circle class="ico-ring" r="3.2" />
			<ellipse class="ico-meridian" rx="1.4" ry="3.2" />
			<line class="ico-meridian" x1="-3.2" y1="0" x2="3.2" y2="0" />
		</g>
		<rect class="line" x="262" y="119.5" width="14" height="3" rx="1.5" />
		<rect class="box" x="322" y="111" width="48" height="10" rx="2.5" />
		<rect class="value-new" x="326" y="114" width="14" height="4" rx="2" />
	</g>
	<!-- e4: rollback to v1 (itself appended) -->
	<g class="append e4">
		<circle class="dot-accent" cx="182" cy="150" r="4" />
		<rect class="entry-hi" x="194" y="136" width="186" height="28" rx="7" />
		<circle class="actor-a" cx="210" cy="150" r="7" />
		<g class="person" transform="translate(210 150)">
			<circle cx="0" cy="-1.6" r="2.4" />
			<path d="M-4.2 4.6 a4.2 3.6 0 0 1 8.4 0 Z" />
		</g>
		<rect class="head" x="223" y="143" width="38" height="4" rx="2" />
		<g transform="translate(226 155)">
			<circle class="ico-ring" r="3.2" />
			<path class="ico-hands" d="M0 -1.8 V0 H1.5" />
		</g>
		<rect class="line" x="232" y="153.5" width="16" height="3" rx="1.5" />
		<g transform="translate(256 155)">
			<circle class="ico-ring" r="3.2" />
			<ellipse class="ico-meridian" rx="1.4" ry="3.2" />
			<line class="ico-meridian" x1="-3.2" y1="0" x2="3.2" y2="0" />
		</g>
		<rect class="line" x="262" y="153.5" width="18" height="3" rx="1.5" />
		<path class="undo-arc" d="M303 147 a5 5 0 1 1 1.2 6" />
		<path class="undo-tip" d="M300.5 144.5 L303 147.6 L306.3 145.3" />
		<rect class="value-box" x="322" y="145" width="48" height="10" rx="2.5" />
		<rect class="muted" x="326" y="148" width="20" height="4" rx="2" />
	</g>
	<circle class="live" cx="182" cy="150" r="4" />

	<!-- Rollback gesture -->
	<rect class="pick" x="192" y="32" width="190" height="32" rx="8" />
	<path class="arrow" pathLength="100" d="M190 48 C164 48 168 115 146 115" />
	<path class="tip" d="M152 110.5 L145.5 115 L152 119.5" />
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
	.entry {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.1;
	}
	.entry-hi {
		fill: var(--accent-weak);
		stroke: var(--accent);
		stroke-width: 1.25;
	}
	.line {
		fill: var(--border);
	}
	.head {
		fill: var(--border-strong);
	}
	.box {
		fill: var(--sunken);
	}
	.chip-a {
		fill: var(--accent);
	}
	.divider {
		stroke: var(--border);
		stroke-width: 1.25;
	}
	.rail {
		stroke: var(--border);
		stroke-width: 2;
	}
	.muted {
		fill: var(--text-3);
	}
	.value-new {
		fill: var(--text-2);
	}
	.value-box {
		fill: var(--surface);
	}
	.dot {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.5;
	}
	.dot-accent {
		fill: var(--accent);
	}
	.actor-a {
		fill: var(--text-2);
	}
	.actor-b {
		fill: var(--accent);
	}
	.actor-c {
		fill: var(--text-3);
	}
	.person {
		fill: var(--surface);
	}
	.ico-ring {
		fill: none;
		stroke: var(--text-3);
		stroke-width: 1.1;
	}
	.ico-hands {
		fill: none;
		stroke: var(--text-3);
		stroke-width: 1.1;
		stroke-linecap: round;
	}
	.ico-meridian {
		fill: none;
		stroke: var(--text-3);
		stroke-width: 1;
	}
	.undo-arc {
		fill: none;
		stroke: var(--accent-ink);
		stroke-width: 1.5;
		stroke-linecap: round;
	}
	.undo-tip {
		fill: none;
		stroke: var(--accent-ink);
		stroke-width: 1.5;
		stroke-linecap: round;
		stroke-linejoin: round;
	}
	.flash {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.5;
	}
	.pick {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.75;
	}
	.arrow {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.75;
		stroke-linecap: round;
	}
	.tip {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.75;
		stroke-linecap: round;
		stroke-linejoin: round;
	}

	/* Base state is the final frame (value back at v1, rollback entry
	   appended); the transient overlays start hidden, so a static render
	   shows the final state. */
	.fade {
		animation: fade 0.4s ease-out both;
	}
	.append {
		animation: append 0.4s cubic-bezier(0.2, 0.8, 0.2, 1) both;
	}
	@keyframes fade {
		from {
			opacity: 0;
		}
		to {
			opacity: 1;
		}
	}
	@keyframes append {
		from {
			opacity: 0;
			transform: translateY(10px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	.doc {
		animation-delay: 0s;
	}
	.rail {
		animation-delay: 0.15s;
	}
	.e1 {
		animation-delay: 0.3s;
	}
	.e2 {
		animation-delay: 0.9s;
	}
	.e3 {
		animation-delay: 1.5s;
	}
	.e4 {
		animation-delay: 2.85s;
	}

	/* Field value history: v2 and v3 overlay the base (v1) until the
	   rollback */
	.v2 {
		opacity: 0;
		animation: v2 2.65s linear both;
	}
	.v3 {
		opacity: 0;
		animation: v3 2.65s linear both;
	}
	@keyframes v2 {
		0%,
		33% {
			opacity: 0;
		}
		35%,
		98% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}
	@keyframes v3 {
		0%,
		56% {
			opacity: 0;
		}
		58%,
		98% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}
	.flash {
		opacity: 0;
		animation: flash 3s ease-out both;
	}
	@keyframes flash {
		0%,
		29% {
			opacity: 0;
		}
		31% {
			opacity: 1;
		}
		40% {
			opacity: 0;
		}
		49% {
			opacity: 0;
		}
		51% {
			opacity: 1;
		}
		60% {
			opacity: 0;
		}
		86% {
			opacity: 0;
		}
		88% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}

	/* Rollback: pick entry 1, draw the arrow to the document, then fade the
	   arrow */
	.pick {
		opacity: 0;
		animation: pick 3.2s ease-out both;
	}
	@keyframes pick {
		0%,
		64% {
			opacity: 0;
		}
		68%,
		90% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}
	.arrow {
		opacity: 0;
		stroke-dasharray: 100;
		animation: arrow 3.4s ease-in-out both;
	}
	@keyframes arrow {
		0%,
		66% {
			opacity: 1;
			stroke-dashoffset: 100;
		}
		78% {
			opacity: 1;
			stroke-dashoffset: 0;
		}
		90% {
			opacity: 1;
			stroke-dashoffset: 0;
		}
		100% {
			opacity: 0;
			stroke-dashoffset: 0;
		}
	}
	.tip {
		opacity: 0;
		animation: tip 3.4s linear both;
	}
	@keyframes tip {
		0%,
		77% {
			opacity: 0;
		}
		79%,
		90% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}

	/* Idle: the newest entry's dot breathes */
	.live {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.5;
		transform-box: fill-box;
		transform-origin: center;
		opacity: 0;
		animation: ring 2.4s ease-out 3.6s infinite;
	}
	@keyframes ring {
		0% {
			opacity: 0.9;
			transform: scale(1);
		}
		70%,
		100% {
			opacity: 0;
			transform: scale(2.2);
		}
	}
</style>

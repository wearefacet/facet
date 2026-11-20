<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	Logo — the official Facet mark and lockup.
	Renders the colored Facet gem (source in `$lib/assets/`): five amber
	facets cut by the signature gap lines, over the base bar. The `lockup`
	variant adds the "facet" wordmark next to the gem. The wordmark is baked
	into the SVG as vector paths — no font dependency — so screens outside
	the app shell (login, reset) show the same type as the brand assets.
	The variant follows the applied theme in CSS — charcoal base on light
	surfaces, white on dark — with the same dual selectors as the token CSS:
	the app pins the theme on `<html data-theme>`, the Storybook preview sets
	a `.dark` class. Both variants render and CSS shows exactly one, so the
	mark cannot diverge from the surface it sits on (the JS theme store is
	app-only; Storybook never initialises it). Native viewBoxes are kept
	(78×58 mark, 234.57×58 lockup). The lockup holds the same gem as the
	mark, so its height equals the mark's height at the same preset and only
	the width grows over the wordmark.
-->
<script lang="ts">
	import logoCharcoal from '$lib/assets/facet-logo-charcoal.svg';
	import logoWhite from '$lib/assets/facet-logo-white.svg';
	import lockupLight from '$lib/assets/facet-lockup-light.svg';
	import lockupDark from '$lib/assets/facet-lockup-dark.svg';

	type Size = 'xs' | 'sm' | 'md' | 'lg' | 'xl';
	type Variant = 'mark' | 'lockup';

	let {
		size = 'md',
		variant = 'mark',
		title = 'Facet'
	}: {
		/** Size preset. Maps to the width (px) of the mark. */
		size?: Size;
		/** `mark` renders the gem alone; `lockup` adds the baked-in wordmark. */
		variant?: Variant;
		/** Accessible label for the mark. */
		title?: string;
	} = $props();

	const px: Record<Size, number> = {
		xs: 16,
		sm: 24,
		md: 32,
		lg: 48,
		xl: 96
	};

	// Native viewBoxes: the mark is 78×58; the lockup puts the same gem next
	// to the wordmark at 234.57×58. Both keep the mark's height at a preset,
	// so the gem size matches across variants and the two sit on one grid.
	const markUnits = 78;
	const lockupUnits = 234.57;

	const height = $derived(Math.round(px[size] * (58 / markUnits)));
	const width = $derived(
		variant === 'lockup' ? Math.round((px[size] * lockupUnits) / markUnits) : px[size]
	);

	const srcLight = $derived(variant === 'lockup' ? lockupLight : logoCharcoal);
	const srcDark = $derived(variant === 'lockup' ? lockupDark : logoWhite);
</script>

<!-- Both variants render; the CSS below shows the one that matches the
     applied theme. Each carries the label — the hidden one is out of the
     accessibility tree, so no duplicate name reaches assistive tech. -->
<img class="logo logo-light" src={srcLight} alt={title} {width} {height} />
<img class="logo logo-dark" src={srcDark} alt={title} {width} {height} />

<style>
	.logo {
		display: block;
		flex: none;
	}

	/* Light surfaces (default): the charcoal-base variant. */
	.logo-dark {
		display: none;
	}

	/* Dark surfaces — the app's `<html data-theme='dark'>` or the Storybook
	   preview's `.dark` class. */
	:global([data-theme='dark']) .logo-light,
	:global(.dark) .logo-light {
		display: none;
	}

	:global([data-theme='dark']) .logo-dark,
	:global(.dark) .logo-dark {
		display: block;
	}

	/* A nested `data-theme='light'` re-pins the light variant inside a dark
	   context — story cards use this to show both variants side by side.
	   These two rules must stay after the dark rules above. */
	:global([data-theme='light']) .logo-light {
		display: block;
	}

	:global([data-theme='light']) .logo-dark {
		display: none;
	}
</style>

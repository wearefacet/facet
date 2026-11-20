// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Ambient module type for `.svelte` imports from plain TypeScript — plain
 * `tsc` (the build's declaration emit) has no Svelte loader. `svelte-check`
 * type-checks the components themselves with the real compiler and does not
 * need this file; the emitted declarations keep .svelte types out of the
 * public surface (the custom-element classes expose no component types).
 */
declare module '*.svelte' {
	import type { Component } from 'svelte';

	const component: Component<Record<string, any>>;
	export default component;
}

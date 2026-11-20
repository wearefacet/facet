<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { setPermissions, setScopes } from '$lib/permissions.svelte';
	import type { PermissionManifest, ScopeManifest } from '$lib/navModel';

	let {
		manifest,
		scopes = null,
		children
	} = $props<{
		manifest: PermissionManifest | null;
		scopes?: ScopeManifest | null;
		children?: import('svelte').Snippet;
	}>();

	// Runs during component initialization, before children render — so
	// `<Can>` inside sees the manifest on its first `$derived` read. Each
	// story mounts a fresh fixture, so only the initial value matters.
	// svelte-ignore state_referenced_locally
	setPermissions(manifest);
	// svelte-ignore state_referenced_locally
	setScopes(scopes);
</script>

{@render children?.()}

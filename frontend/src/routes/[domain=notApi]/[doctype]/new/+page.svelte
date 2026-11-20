<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentForm from '$lib/components/features/document-view/DocumentForm.svelte';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { TemplateNode } from '$lib/template-types';

	let { data } = $props();

	const def = $derived(data.def as DoctypeDef);
	const view = $derived(data.view as { kind: string; template: TemplateNode | null });
</script>

<DocumentForm mode="create" {def} {view} driver={data.driver} />

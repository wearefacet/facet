<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentForm from '$lib/components/features/document-view/DocumentForm.svelte';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { TemplateNode } from '$lib/template-types';

	let { data } = $props();

	const def = $derived(data.def as DoctypeDef);
	const doc = $derived(data.doc as DocumentResponse<Record<string, unknown>>);
	const view = $derived(data.view as { kind: string; template: TemplateNode | null });
</script>

<DocumentForm mode="edit" {def} {view} driver={data.driver} document={doc} />

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import EmailCapsule from '$lib/components/primitives/data/EmailCapsule.svelte';
	import { resolveInterpolated, getDocContent } from '$lib/template-resolve';
	import type { EmailNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';

	let {
		template,
		document,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The email template node. */
		template: EmailNode;
		/** The full document response. */
		document: DocumentResponse;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const email = $derived(resolveInterpolated(template.href, content).replace(/^mailto:/, ''));
	const label = $derived(resolveInterpolated(template.label, content));
</script>

<EmailCapsule {email} {label} {...rest} />

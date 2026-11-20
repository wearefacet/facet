<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	// Distance from the bottom (in px) within which the user is considered
	// "anchored". A small tolerance so rounding or a half-line doesn't break
	// the detection.
	const BOTTOM_THRESHOLD = 40;
</script>

<script lang="ts">
	let {
		children
	}: {
		/** Scrollable conversation content. Usually a `<ChatThread>` with bubbles inside. */
		children?: import('svelte').Snippet;
	} = $props();

	let scrollEl: HTMLElement | null = $state(null);

	// Whether the user is currently anchored to the bottom. Tracked on every
	// scroll event. New content auto-scrolls only while this is true.
	let anchored = $state(true);

	function onScroll() {
		if (!scrollEl) return;
		const { scrollTop, clientHeight, scrollHeight } = scrollEl;
		anchored = scrollTop + clientHeight >= scrollHeight - BOTTOM_THRESHOLD;
	}

	// Observe content changes (new bubbles appended, streaming tokens growing
	// the last bubble) and follow the bottom when anchored. A MutationObserver
	// catches both cases without requiring the caller to thread a `messages`
	// array through.
	let observer: MutationObserver | null = null;

	$effect(() => {
		if (!scrollEl) return;
		observer = new MutationObserver(() => {
			if (anchored && scrollEl) {
				scrollEl.scrollTop = scrollEl.scrollHeight;
			}
		});
		observer.observe(scrollEl, {
			childList: true,
			subtree: true,
			characterData: true
		});
		return () => {
			observer?.disconnect();
			observer = null;
		};
	});

	// On mount, jump to the bottom instantly (e.g. when opening an existing
	// conversation, you want to see the latest turn).
	$effect(() => {
		if (scrollEl) {
			scrollEl.scrollTop = scrollEl.scrollHeight;
		}
	});
</script>

<div bind:this={scrollEl} class="chat-scroll" onscroll={onScroll}>
	{@render children?.()}
</div>

<style>
	.chat-scroll {
		flex: 1;
		overflow-y: auto;
		overflow-x: hidden;
		min-height: 0;
	}
</style>

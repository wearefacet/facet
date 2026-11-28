// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * chapterScroll — the scroll-spy behind the chaptered settings surfaces.
 *
 * The chapter rail shows which section is on screen; this helper owns
 * that state. `scrollTo` jumps to a section and holds the spy while the
 * smooth scroll runs, so the clicked chapter stays selected. `watch`
 * binds the spy to the nearest scrollable ancestor of the shell root
 * (the content pane, or the window as the fallback) and returns the
 * cleanup for the calling `$effect`.
 */

export function createChapterScroll(options: {
	/** Section ids in display order, re-read on every spy tick. */
	ids: () => string[];
	/** Section DOM ids are `${prefix}-${id}`. */
	prefix: string;
}) {
	let active = $state(options.ids()[0]);
	let scrollingToChapter = false;
	let scrollReleaseTimer: ReturnType<typeof setTimeout> | undefined;

	function prefersReducedMotion(): boolean {
		return (
			typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches
		);
	}

	function scrollTo(id: string) {
		const section = document.getElementById(`${options.prefix}-${id}`);
		if (!section) return;
		active = id;
		scrollingToChapter = true;
		clearTimeout(scrollReleaseTimer);
		scrollReleaseTimer = setTimeout(() => {
			scrollingToChapter = false;
		}, 800);
		// A chapter that is already in place emits no scroll event — the
		// spy must run on the next frame or the release timer fires against
		// a document that never moved and `active` keeps the clicked id.
		requestAnimationFrame(spy);
		section.scrollIntoView({
			behavior: prefersReducedMotion() ? 'auto' : 'smooth',
			block: 'start'
		});
	}

	function spy() {
		if (scrollingToChapter) return;
		const ids = options.ids();
		let current = ids[0];
		for (const id of ids) {
			const section = document.getElementById(`${options.prefix}-${id}`);
			if (!section) continue;
			if (section.getBoundingClientRect().top <= 140) current = id;
		}
		active = current;
	}

	function nearestScrollParent(el: HTMLElement): EventTarget {
		let node = el.parentElement;
		while (node) {
			const style = window.getComputedStyle(node);
			if (/(auto|scroll)/.test(style.overflowY)) return node;
			node = node.parentElement;
		}
		return window;
	}

	/** Bind the spy to the scroll parent of `root`. Returns the cleanup. */
	function watch(root: HTMLElement): () => void {
		const target = nearestScrollParent(root);
		const onScroll = () => spy();
		target.addEventListener('scroll', onScroll, { passive: true });
		spy();
		return () => {
			target.removeEventListener('scroll', onScroll);
			// The release timer writes `active` 800 ms after a click — left
			// running past the cleanup it mutates the state of a destroyed
			// component (`derived_inert` in stories that unmount mid-click).
			clearTimeout(scrollReleaseTimer);
		};
	}

	return {
		get active() {
			return active;
		},
		scrollTo,
		watch
	};
}

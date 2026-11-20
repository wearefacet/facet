// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { LayoutLoad } from './$types';

/**
 * Published config detail tab derivation.
 *
 * Mirrors the builder `(editor)/+layout.ts` pattern: explicit static
 * tab segments so they don't collide with `[doctype]` dynamic routes.
 * The published detail exposes `overview`, `doctypes`, `editors`, and
 * `grants` — `check` is draft-only and is hidden here.
 */
const TABS = ['overview', 'doctypes', 'editors', 'grants'] as const;
type Tab = (typeof TABS)[number];

export const load: LayoutLoad = ({ url, params }) => {
	const seg = url.pathname.split('/').filter(Boolean).pop();
	const tab: Tab = TABS.includes(seg as Tab) ? (seg as Tab) : 'overview';
	return { slug: params.slug!, tab };
};

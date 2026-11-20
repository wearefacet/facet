// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { LayoutLoad } from './$types';

const TABS = ['overview', 'doctypes', 'editors', 'grants', 'check'] as const;
type Tab = (typeof TABS)[number];

/**
 * Derives the active domain-editor tab from the last path segment.
 *
 * The four domain tabs are explicit static routes (`overview`,
 * `doctypes`, `editors`, `grants`) — they cannot be collapsed into a
 * `[[tab]]` param without colliding with the sibling `[doctype]` dynamic
 * route. Instead, a route group `(editor)` shares this layout so a single
 * `DomainEditor` instance persists across tab switches (no remount, no
 * domain-doc re-fetch).
 *
 * Reading `url.pathname` re-runs this load on every tab navigation; that is
 * intended and cheap (synchronous string parsing, no network), updating
 * `data.tab` so the persistent `DomainEditor` swaps surfaces reactively.
 */
export const load: LayoutLoad = ({ url }) => {
	const seg = url.pathname.split('/').filter(Boolean).pop();
	const tab: Tab = TABS.includes(seg as Tab) ? (seg as Tab) : 'overview';
	return { tab };
};

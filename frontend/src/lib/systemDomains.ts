// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Bootstrap domains seeded by the backend (`data/seeds/core.Domain`).
 * They carry the schema system (`core`), identity (`iam`), and app hosting
 * (`app`) — the backend refuses to drop them (422), so UI surfaces hide
 * destructive actions for them instead of rendering a dead button.
 */
export const SYSTEM_DOMAINS: readonly string[] = ['core', 'iam', 'app'];

export function isSystemDomain(domain: string): boolean {
	return SYSTEM_DOMAINS.includes(domain);
}

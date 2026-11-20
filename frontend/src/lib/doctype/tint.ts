// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Doctype tint resolution — shared by `Capsule` and the doctype page headers.
 *
 * The fixed Capsule tints are scoped to six color buckets. When we have no
 * per-doctype color (e.g. the doctype definition has no `color`, or the
 * registry has not resolved it yet), the domain name selects a bucket so a
 * document's capsule and header stay tinted consistently across surfaces.
 */

export type DoctypeTint = 'invoice' | 'shipment' | 'contact' | 'task' | 'document' | 'contract';

const DOMAIN_TINT_FALLBACK: Record<string, DoctypeTint> = {
	hr: 'contact',
	crm: 'invoice',
	production: 'task',
	identity: 'document',
	iam: 'document',
	core: 'document'
};

/**
 * Resolve the static tint bucket for a domain, falling back to `'document'`.
 * Pass the doctype definition's `color` when known to override this entirely.
 */
export function doctypeTintForDomain(domain: string): DoctypeTint {
	return DOMAIN_TINT_FALLBACK[domain] ?? 'document';
}

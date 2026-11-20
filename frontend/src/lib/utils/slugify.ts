// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Infers a domain id from a human label, per the live domain-name contract
 * (`^[a-z][a-z0-9-]*$`): strip accents, lowercase, fold runs of non
 * alphanumeric characters into one dash, trim dashes.
 *
 * A label that starts with a digit yields an id that still fails the
 * contract (e.g. "3D Printing" → "3d-printing"). The caller surfaces the
 * validation error instead of inventing a prefix.
 */
export function slugifyDomainLabel(label: string): string {
	return label
		.normalize('NFD')
		.replace(/[\u0300-\u036f]/g, '')
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '-')
		.replace(/^-+|-+$/g, '');
}

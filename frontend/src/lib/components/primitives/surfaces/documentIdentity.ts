// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure identity derivations for the quick-view drawer title area.
 *
 * Every function takes plain data and returns plain data — no DOM access,
 * no Svelte state. `QvIdentity.svelte` feeds its props through these
 * helpers; the spec asserts the current behavior.
 */
import type { DocumentResponse } from '$lib/datasource/types';
import { humanize, type DoctypeDef, type FieldDef } from '$lib/doctype/types.js';

/** The loaded document the identity row renders. */
export type QvDocument = DocumentResponse<Record<string, unknown>>;

/** Tombstone payload of a `410` response. Carries the surviving identity of a deleted document. */
export interface QvDeletedDoc {
	def: DoctypeDef;
	docId: string;
	displayName: string | null;
	deletedAt: string | null;
}

/**
 * Title label for a loaded document: `meta.display_name`, then the
 * conventional label fields (`title`, `name`, `label`), then the raw id.
 */
export function displayLabel(doc: QvDocument | null): string {
	if (!doc) return '';
	const { meta } = doc;
	if (meta.display_name && meta.display_name.length > 0) return meta.display_name;
	// No `display_name` template on the doctype (or a hand-written row whose
	// `projections.display_name` is null): fall back to common label fields,
	// then the raw id — mirroring `Capsule.deriveFallbackLabel`.
	const content = (doc.data ?? {}) as Record<string, unknown>;
	for (const k of ['title', 'name', 'label'] as const) {
		const v = content[k];
		if (typeof v === 'string' && v.length > 0) return v;
	}
	return meta.id;
}

/**
 * Secondary line under the title. Probes the subtitle fields in order and
 * trims the first non-empty one. Returns '' when none carries a value.
 */
export function subLabel(doc: QvDocument | null): string {
	if (!doc) return '';
	const content = (doc.data ?? {}) as Record<string, unknown>;
	for (const k of ['headline', 'subtitle', 'description', 'summary'] as const) {
		const v = content[k];
		if (typeof v === 'string' && v.trim().length > 0) {
			// Long-form fields (summary) get clamped to one line.
			return v.trim();
		}
	}
	return '';
}

/** The doctype's `status` field, but only when it is an enum. */
export function statusFieldOf(def: DoctypeDef): FieldDef | null {
	const f = def.fields.find((fd) => fd.key === 'status');
	return f && f.type === 'enum' ? f : null;
}

/** The document's `status` value. Returns null when it is missing, empty, or not a string. */
export function statusValueOf(doc: QvDocument | null, field: FieldDef | null): string | null {
	if (!doc || !field) return null;
	const content = (doc.data ?? {}) as Record<string, unknown>;
	const raw = content['status'];
	if (raw == null || typeof raw !== 'string' || raw.length === 0) return null;
	return raw;
}

/** Humanized badge label for a status value. Returns null without a value. */
export function statusBadgeLabel(value: string | null): string | null {
	return value ? humanize(value) : null;
}

/** Color of the enum entry that matches the value. Returns undefined when there is no match. */
export function statusBadgeTint(field: FieldDef | null, value: string | null): string | undefined {
	if (!field || !value) return undefined;
	const entry = field.values?.find((e) => e.key === value);
	return entry?.color;
}

/** Avatar image URL from the conventional fields, in order. Returns null when none has a string value. */
export function photoUrlOf(doc: QvDocument | null): string | null {
	if (!doc) return null;
	const content = (doc.data ?? {}) as Record<string, unknown>;
	for (const k of ['photo', 'avatar_url', 'icon'] as const) {
		const v = content[k];
		if (typeof v === 'string' && v.length > 0) return v;
	}
	return null;
}

/** Up to two uppercase initials from the label. Returns '#' when the label is empty. */
export function initialsFromLabel(label: string): string {
	const trimmed = label.trim();
	if (trimmed.length === 0) return '#';
	const parts = trimmed.split(/\s+/).filter((p) => p.length > 0);
	const first = parts[0]?.[0] ?? '';
	const second = parts.length > 1 ? parts[1][0] : '';
	return (first + second).toUpperCase() || '#';
}

/** Humanized `source` field value. Returns null when it is absent, empty, or not a string. */
export function sourceLabelOf(doc: QvDocument | null): string | null {
	if (!doc) return null;
	const content = (doc.data ?? {}) as Record<string, unknown>;
	const v = content['source'];
	if (v == null) return null;
	if (typeof v === 'string' && v.length > 0) return humanize(v);
	return null;
}

/** Avatar tint: the doctype accent color, else the brand accent. */
export function avatarTintOf(def: DoctypeDef): string {
	return def.color ?? 'var(--accent)';
}

/** Title for a deleted document: the surviving display name, else the qualified doctype name. */
export function deletedTitle(deleted: QvDeletedDoc): string {
	return deleted.displayName ?? `${deleted.def.domain}.${deleted.def.doctype}`;
}

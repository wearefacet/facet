// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Serializes one list-filter value for the query string.
 *
 * Scalars keep their string form (the backend reads every `filters[...]`
 * param as a string — numeric-string comparisons rely on it). Arrays
 * cannot cross a query string as scalars: `String(value)` would flatten
 * them to a comma-joined string that no backend operator parses, and a
 * `__between` lane would silently match nothing. They go out JSON-encoded
 * instead; the backend decodes a `filters[...]` value that parses as a
 * JSON array back into a real array (`HTTP::ListRequest.from_query`).
 *
 * Shared by every client that emits the `filters[key]=value` wire form:
 * `DocumentDataSource`, `AuditSource`, `ArtifactsSource`, `IndexesSource`,
 * and the assistant driver.
 */
export function serializeFilterValue(value: unknown): string {
	return Array.isArray(value) ? JSON.stringify(value) : String(value);
}

/**
 * Inbound decode for one `filters[...]` query value — the mirror of
 * {@link serializeFilterValue}. A value that parses as a JSON array decodes
 * back into a real array; every other value keeps its raw string form. This
 * is the backend's own rule (`HTTP::ListRequest.from_query`): scalar values
 * stay strings so numeric-string comparisons are unchanged, and only an
 * array round-trips through JSON.
 */
export function deserializeFilterValue(raw: string): unknown {
	const trimmed = raw.trim();
	if (trimmed.startsWith('[')) {
		try {
			const parsed: unknown = JSON.parse(trimmed);
			if (Array.isArray(parsed)) return parsed;
		} catch {
			/* not a JSON array — keep the raw string */
		}
	}
	return raw;
}

/**
 * Parse inbound `filters[key__op]` query params into the DataSource filter
 * map — the inverse of the outbound writer in `DocumentDataSource`
 * (`query.set(`filters[${key}]`, serializeFilterValue(value))`). This is what
 * makes a filtered listing shareable as a URL (B-376). Keys outside the
 * `filters[...]` lane are ignored; for a duplicated key the last value wins,
 * mirroring `URLSearchParams.get`.
 */
export function parseFilterParams(entries: Iterable<[string, string]>): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	for (const [key, value] of entries) {
		const match = /^filters\[([^\]]+)\]$/.exec(key);
		if (!match) continue;
		out[match[1]] = deserializeFilterValue(value);
	}
	return out;
}

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Color conversion utilities — OKLCH ↔ sRGB ↔ Hex
 *
 * All conversions operate in the OKLCH color space. The honeycomb
 * picker generates cells at discrete (L, C, H) points and converts
 * them to hex for rendering.
 */

/* ── OKLCH → linear sRGB ─────────────────────────────────────────────── */
function oklchToLin(L: number, C: number, H: number): [number, number, number] {
	const h = (H * Math.PI) / 180;
	const a = C * Math.cos(h);
	const b = C * Math.sin(h);

	const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
	const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
	const s_ = L - 0.0894841775 * a - 1.291485548 * b;

	const l = l_ ** 3;
	const m = m_ ** 3;
	const s = s_ ** 3;

	return [
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s
	];
}

/* ── sRGB gamma helpers ──────────────────────────────────────────────── */
const g2s = (c: number) => (c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055);
const s2g = (c: number) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));

/* ── Gamut check & chroma clamp ──────────────────────────────────────── */
function inGamut(L: number, C: number, H: number): boolean {
	const [r, g, b] = oklchToLin(L, C, H);
	return r >= -1e-4 && r <= 1.0001 && g >= -1e-4 && g <= 1.0001 && b >= -1e-4 && b <= 1.0001;
}

/** Binary search for maximum chroma in-gamut at (L, H). */
function maxChroma(L: number, H: number): number {
	let lo = 0;
	let hi = 0.4;
	for (let i = 0; i < 20; i++) {
		const m = (lo + hi) / 2;
		if (inGamut(L, m, H)) {
			lo = m;
		} else {
			hi = m;
		}
	}
	return lo;
}

/* ── Public API ──────────────────────────────────────────────────────── */

/** Convert OKLCH to hex string (uppercase, e.g. `#5B8DEF`). */
export function toHex(L: number, C: number, H: number): string {
	const p = oklchToLin(L, C, H).map((c) => Math.round(Math.min(1, Math.max(0, g2s(c))) * 255));
	return (
		'#' +
		p
			.map((v) => v.toString(16).padStart(2, '0'))
			.join('')
			.toUpperCase()
	);
}

/** Convert OKLCH to CSS `oklch(L C H)` string. */
export function oklchCss(L: number, C: number, H: number): string {
	return `oklch(${L.toFixed(3)} ${C.toFixed(3)} ${H.toFixed(1)})`;
}

/** Convert a `#RRGGBB` hex string to `{L, C, H}`. Returns `null` for invalid input. */
export function hexToOklch(hex: string): { L: number; C: number; H: number } | null {
	const n = hex.replace('#', '');
	if (n.length !== 6) return null;
	const r = s2g(parseInt(n.slice(0, 2), 16) / 255);
	const g = s2g(parseInt(n.slice(2, 4), 16) / 255);
	const b = s2g(parseInt(n.slice(4, 6), 16) / 255);

	const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
	const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
	const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);

	const L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
	const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
	const B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;

	return { L, C: Math.hypot(A, B), H: (Math.atan2(B, A) * (180 / Math.PI) + 360) % 360 };
}

/* ── Hex grid geometry ───────────────────────────────────────────────── */

export interface HoneyCell {
	q: number;
	r: number;
	x: number;
	y: number;
	l: number;
	c: number;
	h: number;
	hex: string;
}

/** Hex grid distance in axial coordinates. */
function hexDist(q: number, r: number): number {
	return (Math.abs(q) + Math.abs(r) + Math.abs(q + r)) / 2;
}

function ringTone(ring: number, rings: number): { L: number; Cf: number } {
	if (ring === 0) return { L: 0.965, Cf: 0 };
	const t = ring / rings;
	return { L: 0.95 - 0.33 * t, Cf: 0.3 + 0.62 * t };
}

function cellColor(
	q: number,
	r: number,
	rings: number,
	S: number
): { L: number; C: number; H: number } {
	const ring = hexDist(q, r);
	const { L, Cf } = ringTone(ring, rings);
	if (ring === 0) return { L, C: 0, H: 0 };
	const x = S * Math.sqrt(3) * (q + r / 2);
	const y = S * 1.5 * r;
	const H = ((Math.atan2(y, x) * 180) / Math.PI + 360 + 90) % 360;
	return { L, C: Cf * maxChroma(L, H), H };
}

/** Generate the full set of honeycomb cells. */
export function generateCells(rings: number, S: number): HoneyCell[] {
	const cells: HoneyCell[] = [];
	for (let q = -rings; q <= rings; q++) {
		for (let r = -rings; r <= rings; r++) {
			if (hexDist(q, r) > rings) continue;
			const x = S * Math.sqrt(3) * (q + r / 2);
			const y = S * 1.5 * r;
			const { L, C, H } = cellColor(q, r, rings, S);
			cells.push({ q, r, x, y, l: L, c: C, h: H, hex: toHex(L, C, H) });
		}
	}
	return cells;
}

/** Compute SVG `points` attribute for a hexagon centered at (cx, cy). */
export function hexPts(cx: number, cy: number, S: number): string {
	let p = '';
	for (let i = 0; i < 6; i++) {
		const a = ((-90 + 60 * i) * Math.PI) / 180;
		p += `${(cx + S * 0.93 * Math.cos(a)).toFixed(2)},${(cy + S * 0.93 * Math.sin(a)).toFixed(2)} `;
	}
	return p.trim();
}

/* ── Neutral grey cells ──────────────────────────────────────────────── */

/** Default lightness values for the neutral grey rail (near-white → near-black). */
export const NEUTRAL_L_VALUES = [0.97, 0.86, 0.74, 0.62, 0.48, 0.35, 0.22];

/** Generate grey-scale cells for a 1D neutrals rail. */
export function generateNeutralCells(Ls: number[], S: number): HoneyCell[] {
	const gap = S * Math.sqrt(3);
	return Ls.map((L, i) => {
		const x = i * gap;
		return { q: i, r: 0, x, y: 0, l: L, c: 0, h: 0, hex: toHex(L, 0, 0) };
	});
}

/** Compute viewBox for a neutrals rail. */
export function computeRailViewBox(nCells: HoneyCell[], S: number): string {
	const minX = nCells.length > 0 ? nCells[0].x - (S * Math.sqrt(3)) / 2 : -S;
	const maxX = nCells.length > 0 ? nCells[nCells.length - 1].x + (S * Math.sqrt(3)) / 2 : S;
	return `${minX} ${-S} ${maxX - minX} ${2 * S}`;
}

/* ── Stable hash color ───────────────────────────────────────────────── */

/**
 * Deterministic OKLCH-based color derived from a string seed.
 *
 * Used as a fallback when an entity (doctype, domain, …) has no explicit
 * color: the seed is hashed to a stable hue, then converted to hex via the
 * OKLCH pipeline so the result is readable on both light and dark themes.
 *
 * Lightness and chroma are fixed so all hash colors share the same visual
 * weight — only the hue varies with the seed.
 *
 * @param seed  Any stable identifier (e.g. `"hr.Candidate"`).
 * @returns A `#RRGGBB` hex string.
 */
export function hashColor(seed: string): string {
	// FNV-1a 32-bit — small, fast, well-distributed for short strings.
	let h = 0x811c9dc5;
	for (let i = 0; i < seed.length; i++) {
		h ^= seed.charCodeAt(i);
		h = Math.imul(h, 0x01000193);
	}
	const hue = (h >>> 0) % 360;
	// L=0.58, C=0.11 — mid-light, moderate chroma; reads on light & dark grounds.
	return toHex(0.58, 0.11, hue);
}

/** Compute an SVG viewBox string that fits all honeycomb cells with padding. */
export function computeViewBox(cells: HoneyCell[], S: number): string {
	const minX = Math.min(...cells.map((c) => c.x)) - (S * Math.sqrt(3)) / 2;
	const maxX = Math.max(...cells.map((c) => c.x)) + (S * Math.sqrt(3)) / 2;
	const minY = Math.min(...cells.map((c) => c.y)) - S;
	const maxY = Math.max(...cells.map((c) => c.y)) + S;
	return `${minX} ${minY} ${maxX - minX} ${maxY - minY}`;
}

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { bezierMid, bezierPath, borderPoint, center, fitViewBox } from './geometry.js';
import type { SchematicNode } from './types.js';

function node(id: string, x: number, y: number, w = 100, h = 50): SchematicNode {
	return { id, label: id, color: '#000', x, y, width: w, height: h };
}

describe('center', () => {
	it('returns the geometric center', () => {
		expect(center(node('a', 0, 0, 100, 50))).toEqual({ x: 50, y: 25 });
		expect(center(node('b', 10, 20, 40, 60))).toEqual({ x: 30, y: 50 });
	});
});

describe('borderPoint', () => {
	it('exits the right edge when target is to the right', () => {
		const a = node('a', 0, 0, 100, 50);
		const b = node('b', 200, 0, 100, 50);
		const p = borderPoint(a, b);
		expect(p.x).toBeCloseTo(100);
		expect(p.y).toBeCloseTo(25);
	});

	it('exits the left edge when target is to the left', () => {
		const a = node('a', 200, 0, 100, 50);
		const b = node('b', 0, 0, 100, 50);
		const p = borderPoint(a, b);
		expect(p.x).toBeCloseTo(200);
		expect(p.y).toBeCloseTo(25);
	});

	it('exits the bottom edge when target is directly below', () => {
		const a = node('a', 0, 0, 100, 50);
		const b = node('b', 0, 200, 100, 50);
		const p = borderPoint(a, b);
		expect(p.x).toBeCloseTo(50);
		expect(p.y).toBeCloseTo(50);
	});
});

describe('bezierPath', () => {
	it('starts with an M command and contains a C command', () => {
		const a = node('a', 0, 0);
		const b = node('b', 200, 0);
		const d = bezierPath(a, b);
		expect(d.startsWith('M ')).toBe(true);
		expect(d).toContain(' C ');
	});
});

describe('bezierMid', () => {
	it('returns a point between the two nodes', () => {
		const a = node('a', 0, 0, 100, 50);
		const b = node('b', 200, 0, 100, 50);
		const mid = bezierMid(a, b);
		expect(mid.x).toBeGreaterThan(100);
		expect(mid.x).toBeLessThan(200);
		expect(mid.y).toBeCloseTo(25);
	});
});

describe('fitViewBox', () => {
	it('returns a zero box for no nodes', () => {
		expect(fitViewBox([])).toEqual({ x: 0, y: 0, width: 0, height: 0 });
	});

	it('bounds all nodes with padding', () => {
		const nodes = [node('a', 0, 0, 100, 50), node('b', 200, 100, 100, 50)];
		const vb = fitViewBox(nodes, 10);
		expect(vb.x).toBe(-10);
		expect(vb.y).toBe(-10);
		expect(vb.width).toBe(320);
		expect(vb.height).toBe(170);
	});
});

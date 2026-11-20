// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import {
	createLayoutSaver,
	mergePositions,
	parseStoredPositions,
	positionsPayload,
	type SchematicPositions
} from './layout.js';

const NODES = [
	{ id: 'production.Project', x: 40, y: 40 },
	{ id: 'production.Team', x: 40, y: 192 },
	{ id: 'production.Task', x: 260, y: 40 }
];

describe('parseStoredPositions', () => {
	it('extracts finite positions from document content', () => {
		expect(
			parseStoredPositions({
				domain: 'production',
				positions: { 'production.Project': { x: 500, y: 400 } }
			})
		).toEqual({ 'production.Project': { x: 500, y: 400 } });
	});

	it('drops malformed entries and keeps the rest', () => {
		expect(
			parseStoredPositions({
				positions: {
					a: { x: 1, y: 2 },
					b: { x: 'nan', y: 2 },
					c: { x: 3 },
					d: 'junk',
					e: null
				}
			})
		).toEqual({ a: { x: 1, y: 2 } });
	});

	it('returns null for a missing document or an empty map', () => {
		expect(parseStoredPositions(undefined)).toBeNull();
		expect(parseStoredPositions(null)).toBeNull();
		expect(parseStoredPositions({})).toBeNull();
		expect(parseStoredPositions({ positions: {} })).toBeNull();
		expect(parseStoredPositions({ positions: 'junk' })).toBeNull();
	});
});

describe('mergePositions', () => {
	it('stored wins over computed; missing nodes keep computed', () => {
		const stored: SchematicPositions = { 'production.Team': { x: 900, y: 700 } };
		expect(mergePositions(NODES, stored)).toEqual({
			'production.Project': { x: 40, y: 40 },
			'production.Team': { x: 900, y: 700 },
			'production.Task': { x: 260, y: 40 }
		});
	});

	it('ignores stored keys with no matching node', () => {
		const stored: SchematicPositions = {
			'production.Gone': { x: 5, y: 5 },
			'production.Project': { x: 1, y: 2 }
		};
		const merged = mergePositions(NODES, stored);
		expect(Object.keys(merged).sort()).toEqual([
			'production.Project',
			'production.Task',
			'production.Team'
		]);
		expect(merged['production.Project']).toEqual({ x: 1, y: 2 });
	});

	it('null or undefined stored falls back to computed everywhere', () => {
		expect(mergePositions(NODES, null)).toEqual({
			'production.Project': { x: 40, y: 40 },
			'production.Team': { x: 40, y: 192 },
			'production.Task': { x: 260, y: 40 }
		});
	});
});

describe('positionsPayload', () => {
	it('rounds to integers and follows the current nodes', () => {
		expect(
			positionsPayload(NODES, {
				'production.Project': { x: 512.6, y: 388.2 },
				'production.Team': { x: 40, y: 192 },
				'production.Task': { x: 260.4, y: 40 },
				'production.Stale': { x: 9, y: 9 }
			})
		).toEqual({
			'production.Project': { x: 513, y: 388 },
			'production.Team': { x: 40, y: 192 },
			'production.Task': { x: 260, y: 40 }
		});
	});

	it('drops a node with no live position', () => {
		expect(positionsPayload(NODES, { 'production.Project': { x: 1, y: 2 } })).toEqual({
			'production.Project': { x: 1, y: 2 }
		});
	});
});

describe('createLayoutSaver', () => {
	it('fires one trailing save after the debounce window', async () => {
		vi.useFakeTimers();
		try {
			const save = vi.fn(async () => {});
			const saver = createLayoutSaver(save, 500);

			saver.schedule('production', { a: { x: 1, y: 1 } });
			await vi.advanceTimersByTimeAsync(200);
			saver.schedule('production', { a: { x: 2, y: 2 } });
			await vi.advanceTimersByTimeAsync(200);
			expect(save).not.toHaveBeenCalled();

			await vi.advanceTimersByTimeAsync(500);
			expect(save).toHaveBeenCalledOnce();
			expect(save).toHaveBeenCalledWith('production', { a: { x: 2, y: 2 } });
		} finally {
			vi.useRealTimers();
		}
	});

	it('cancel drops the pending save', async () => {
		vi.useFakeTimers();
		try {
			const save = vi.fn(async () => {});
			const saver = createLayoutSaver(save, 500);
			saver.schedule('production', { a: { x: 1, y: 1 } });
			saver.cancel();
			await vi.advanceTimersByTimeAsync(1000);
			expect(save).not.toHaveBeenCalled();
		} finally {
			vi.useRealTimers();
		}
	});

	it('captures the domain at schedule time', async () => {
		vi.useFakeTimers();
		try {
			const save = vi.fn(async () => {});
			const saver = createLayoutSaver(save, 500);
			saver.schedule('production', { a: { x: 1, y: 1 } });
			saver.cancel();
			saver.schedule('crm', { b: { x: 2, y: 2 } });
			await vi.advanceTimersByTimeAsync(500);
			expect(save).toHaveBeenCalledOnce();
			expect(save).toHaveBeenCalledWith('crm', { b: { x: 2, y: 2 } });
		} finally {
			vi.useRealTimers();
		}
	});
});

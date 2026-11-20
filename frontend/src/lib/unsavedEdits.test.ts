// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { beforeEach, describe, expect, it } from 'vitest';
import { clearUnsavedEditsGate, hasUnsavedEdits, setUnsavedEditsGate } from './unsavedEdits.js';

describe('unsavedEdits gate registry', () => {
	beforeEach(() => {
		// The registry is module state — start every example clean.
		setUnsavedEditsGate(() => false);
		clearUnsavedEditsGate(() => false);
	});

	it('answers false when no gate is registered', () => {
		expect(hasUnsavedEdits()).toBe(false);
	});

	it('mirrors the active gate answer', () => {
		let dirty = false;
		setUnsavedEditsGate(() => dirty);
		expect(hasUnsavedEdits()).toBe(false);
		dirty = true;
		expect(hasUnsavedEdits()).toBe(true);
	});

	it('lets the last registration win', () => {
		setUnsavedEditsGate(() => true);
		setUnsavedEditsGate(() => false);
		expect(hasUnsavedEdits()).toBe(false);
	});

	it('keeps the active gate when a stale owner clears', () => {
		const active = () => true;
		const stale = () => false;
		setUnsavedEditsGate(active);
		setUnsavedEditsGate(stale);
		clearUnsavedEditsGate(active);
		// The late cleanup of the replaced owner must not clear the new one.
		expect(hasUnsavedEdits()).toBe(false);

		setUnsavedEditsGate(active);
		setUnsavedEditsGate(stale);
		clearUnsavedEditsGate(stale);
		expect(hasUnsavedEdits()).toBe(false);
	});
});

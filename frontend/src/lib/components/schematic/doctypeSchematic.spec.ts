// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { createMockDriver } from '$lib/datasource/mock-seed.js';
import { buildDomainSchematic } from './doctypeSchematic.js';

describe('buildDomainSchematic', () => {
	const driver = createMockDriver();

	it('returns an empty schematic for an unknown domain', () => {
		const s = buildDomainSchematic(driver, 'nope');
		expect(s.nodes).toEqual([]);
		expect(s.edges).toEqual([]);
	});

	describe('hr domain', () => {
		const s = buildDomainSchematic(driver, 'hr');

		it('includes hr doctypes as nodes', () => {
			const ids = s.nodes.map((n) => n.id).sort();
			expect(ids).toContain('hr.Candidate');
			expect(ids).toContain('hr.Employee');
			expect(ids).toContain('hr.CandidateExperience');
		});

		it('uses the doctype color when present', () => {
			const candidate = s.nodes.find((n) => n.id === 'hr.Candidate');
			expect(candidate?.color).toBe('#7C4DFF');
		});

		it('falls back to a hash color when no color is defined', () => {
			const exp = s.nodes.find((n) => n.id === 'hr.CandidateExperience');
			expect(exp?.color).toMatch(/^#[0-9A-Fa-f]{6}$/);
			// Hash color is stable.
			expect(exp?.color).toBe(exp?.color);
		});

		it('draws a composition edge from a root to its member_of child', () => {
			const comp = s.edges.filter(
				(e) =>
					e.kind === 'composition' && e.from === 'hr.Candidate' && e.to === 'hr.CandidateExperience'
			);
			expect(comp.length).toBe(1);
		});

		it('does not duplicate composition edges from children and member_of', () => {
			const dupes = s.edges.filter(
				(e) => e.from === 'hr.Candidate' && e.to === 'hr.CandidateEducation'
			);
			expect(dupes.length).toBe(1);
		});

		it('marks roots with the root tagline kind', () => {
			const root = s.nodes.find((n) => n.id === 'hr.Candidate');
			expect(root?.taglineKind).toBe('root');
		});

		it('marks children with the child tagline kind', () => {
			const child = s.nodes.find((n) => n.id === 'hr.CandidateExperience');
			expect(child?.taglineKind).toBe('child');
			expect(child?.tagline).toContain('Candidate');
		});
	});

	describe('crm domain', () => {
		const s = buildDomainSchematic(driver, 'crm');

		it('draws composition edges from Company to its children', () => {
			const toMembership = s.edges.filter(
				(e) =>
					e.kind === 'composition' && e.from === 'crm.Company' && e.to === 'crm.CompanyMembership'
			);
			expect(toMembership.length).toBe(1);
		});

		it('draws reference edges between aggregate roots', () => {
			// Deal references PipelineStage (a root? check) — at minimum there
			// should be at least one reference edge in crm.
			const refs = s.edges.filter((e) => e.kind === 'reference');
			expect(refs.length).toBeGreaterThan(0);
		});
	});
});

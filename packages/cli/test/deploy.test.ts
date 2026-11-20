// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DeployError, buildDeployBody, loadBuildFiles, walkBuild } from '../src/deploy.js';

let root: string;

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-deploy-'));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
});

function write(paths: string[]): void {
	for (const relative of paths) {
		const target = path.join(root, relative);
		mkdirSync(path.dirname(target), { recursive: true });
		writeFileSync(target, `content of ${relative}`);
	}
}

describe('walkBuild', () => {
	it('lists nested files as sorted relative POSIX paths', () => {
		write(['index.html', 'assets/app.js', 'assets/img/logo.svg']);

		expect(walkBuild(root)).toEqual(['assets/app.js', 'assets/img/logo.svg', 'index.html']);
	});

	it('skips node_modules and .git directories at every depth', () => {
		write([
			'index.html',
			'node_modules/pkg/index.js',
			'sub/node_modules/pkg/index.js',
			'.git/HEAD'
		]);

		expect(walkBuild(root)).toEqual(['index.html']);
	});

	it('skips .DS_Store files at every depth', () => {
		write(['index.html', '.DS_Store', 'assets/.DS_Store']);

		expect(walkBuild(root)).toEqual(['index.html']);
	});

	it('rejects a missing build folder', () => {
		const missing = path.join(root, 'nowhere');

		expect(() => walkBuild(missing)).toThrow(DeployError);
		expect(() => walkBuild(missing)).toThrow(/does not exist/);
	});

	it('rejects a build folder that is a file', () => {
		const file = path.join(root, 'build');
		writeFileSync(file, 'not a folder');

		expect(() => walkBuild(file)).toThrow(/not a directory/);
	});

	it('rejects an empty build folder', () => {
		expect(() => walkBuild(root)).toThrow(DeployError);
		expect(() => walkBuild(root)).toThrow(/holds no files/);
	});

	it('rejects a build folder that only holds skipped entries', () => {
		write(['node_modules/pkg/index.js', '.DS_Store']);

		expect(() => walkBuild(root)).toThrow(/holds no files/);
	});
});

/** Seeds the standard two-file fixture and returns its walk list with real bytes. */
function fixtureFiles(): { path: string; bytes: Uint8Array }[] {
	write(['index.html', 'assets/app.js']);
	return walkBuild(root).map((relative) => ({
		path: relative,
		bytes: new Uint8Array(readFileSync(path.join(root, relative)))
	}));
}

async function parseBody(multipart: { body: Uint8Array; contentType: string }): Promise<FormData> {
	const response = new Response(multipart.body, {
		headers: { 'content-type': multipart.contentType }
	});
	return response.formData();
}

describe('loadBuildFiles', () => {
	it("reads every walked file's bytes in walk order", () => {
		write(['index.html', 'assets/app.js']);

		const files = loadBuildFiles(root);

		expect(files.map((file) => file.path)).toEqual(['assets/app.js', 'index.html']);
		expect(files.map((file) => new TextDecoder().decode(file.bytes))).toEqual([
			'content of assets/app.js',
			'content of index.html'
		]);
	});

	it("propagates the walk's clear errors", () => {
		expect(() => loadBuildFiles(root)).toThrow(DeployError);
		expect(() => loadBuildFiles(root)).toThrow(/holds no files/);
	});
});

describe('buildDeployBody', () => {
	it('carries the $content JSON with note, spa, and activate passthrough', async () => {
		const multipart = buildDeployBody({
			note: 'first build',
			spa: true,
			activate: true,
			files: fixtureFiles()
		});

		const form = await parseBody(multipart);
		const content = JSON.parse(form.get('$content') as string) as {
			note?: string;
			spa: boolean;
			activate: boolean;
			files: { path: string }[];
		};

		expect(content.note).toBe('first build');
		expect(content.spa).toBe(true);
		expect(content.activate).toBe(true);
	});

	it('reflects activate false from the flag', async () => {
		const multipart = buildDeployBody({ spa: false, activate: false, files: fixtureFiles() });

		const form = await parseBody(multipart);
		const content = JSON.parse(form.get('$content') as string) as {
			activate: boolean;
			spa: boolean;
		};

		expect(content.activate).toBe(false);
		expect(content.spa).toBe(false);
	});

	it('omits the note when none is given', async () => {
		const multipart = buildDeployBody({ spa: true, activate: true, files: fixtureFiles() });

		const form = await parseBody(multipart);
		const content = JSON.parse(form.get('$content') as string) as Record<string, unknown>;

		expect('note' in content).toBe(false);
	});

	it('names the file parts files[0].file onward, in files order', async () => {
		const multipart = buildDeployBody({ spa: true, activate: true, files: fixtureFiles() });

		const form = await parseBody(multipart);
		const names = [...form.keys()];

		expect(names).toEqual(['$content', 'files[0].file', 'files[1].file']);
	});

	it('sends the file bytes in the matching parts', async () => {
		const files = fixtureFiles();
		const multipart = buildDeployBody({ spa: true, activate: true, files });

		const form = await parseBody(multipart);
		for (const [index, file] of files.entries()) {
			const part = form.get(`files[${index}].file`);
			expect(part, `files[${index}].file`).toBeInstanceOf(File);
			const sent = new Uint8Array(await (part as File).arrayBuffer());
			expect(sent).toEqual(file.bytes);
		}
	});

	it('carries the walk output as the path values', async () => {
		const files = fixtureFiles();
		const multipart = buildDeployBody({ spa: true, activate: true, files });

		const form = await parseBody(multipart);
		const content = JSON.parse(form.get('$content') as string) as { files: { path: string }[] };

		expect(content.files.map((entry) => entry.path)).toEqual(['assets/app.js', 'index.html']);
	});

	it('labels the content type as multipart with a boundary', () => {
		const multipart = buildDeployBody({ spa: true, activate: true, files: fixtureFiles() });

		expect(multipart.contentType).toMatch(/^multipart\/form-data; boundary=facet-cli-/);
	});

	it('rejects an empty file list', () => {
		expect(() => buildDeployBody({ spa: true, activate: true, files: [] })).toThrow(DeployError);
		expect(() => buildDeployBody({ spa: true, activate: true, files: [] })).toThrow(/No files/);
	});
});

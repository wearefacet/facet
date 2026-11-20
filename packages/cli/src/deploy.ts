// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { randomBytes } from 'node:crypto';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

/** Raised when the build folder cannot be deployed. */
export class DeployError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'DeployError';
	}
}

/** Directories never worth shipping in a build. */
const SKIPPED_DIRECTORIES = new Set(['node_modules', '.git']);

/** Junk files never worth shipping in a build. */
const SKIPPED_FILES = new Set(['.DS_Store']);

/** One deployable file: its POSIX path relative to the build folder, plus its bytes. */
export interface DeployFile {
	path: string;
	bytes: Uint8Array;
}

/**
 * Lists the deployable files under `outDir` as POSIX paths relative to it,
 * in stable sorted order. Skips `node_modules` and `.git` directories and
 * `.DS_Store` files at every depth. Raises `DeployError` when the folder is
 * missing, not a directory, or holds no files.
 */
export function walkBuild(outDir: string): string[] {
	const resolved = path.resolve(outDir);
	let rootStat: ReturnType<typeof statSync>;
	try {
		rootStat = statSync(resolved);
	} catch {
		throw new DeployError(
			`The build folder "${outDir}" does not exist. Check "outDir" in facet.config.json.`
		);
	}
	if (!rootStat.isDirectory()) {
		throw new DeployError(`The build folder "${outDir}" is not a directory.`);
	}

	const files: string[] = [];
	visit(resolved, '', files);
	files.sort();
	if (files.length === 0) {
		throw new DeployError(`The build folder "${outDir}" holds no files to deploy.`);
	}
	return files;
}

/**
 * Walks the build folder and reads every file's bytes, in the walk's stable
 * sorted order. The result feeds `buildDeployBody` directly.
 */
export function loadBuildFiles(outDir: string): DeployFile[] {
	const resolved = path.resolve(outDir);
	return walkBuild(resolved).map((relative) => ({
		path: relative,
		bytes: readFileSync(path.join(resolved, relative))
	}));
}

function visit(dir: string, prefix: string, files: string[]): void {
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const relative = prefix === '' ? entry.name : `${prefix}/${entry.name}`;
		if (entry.isDirectory()) {
			if (SKIPPED_DIRECTORIES.has(entry.name)) {
				continue;
			}
			visit(path.join(dir, entry.name), relative, files);
		} else if (entry.isFile() || entry.isSymbolicLink()) {
			if (SKIPPED_FILES.has(entry.name)) {
				continue;
			}
			files.push(relative);
		}
	}
}

export interface DeployBodyOptions {
	/** Short note attached to the deployment. Omitted when undefined. */
	note?: string;
	spa: boolean;
	activate: boolean;
	/** The files to upload, in the order the parts must follow. */
	files: DeployFile[];
}

/** A prepared multipart body plus the content type header to send with it. */
export interface MultipartBody {
	body: Uint8Array;
	contentType: string;
}

/**
 * Encodes the deploy request body: the `$content` part carries
 * `{note, spa, activate, files: [{path}]}`, then one part per file named
 * `files[<i>].file`, in the same order as the `files` entries. The server
 * injects the artifact ids, so the JSON must not carry any `file` values.
 */
export function buildDeployBody(options: DeployBodyOptions): MultipartBody {
	if (options.files.length === 0) {
		throw new DeployError('No files to deploy.');
	}

	const content: Record<string, unknown> = {
		spa: options.spa,
		activate: options.activate,
		files: options.files.map((file) => ({ path: file.path }))
	};
	if (options.note !== undefined) {
		content['note'] = options.note;
	}

	const boundary = `facet-cli-${randomBytes(16).toString('hex')}`;
	const encoder = new TextEncoder();
	const chunks: Uint8Array[] = [];

	chunks.push(encoder.encode(`--${boundary}\r\n`));
	chunks.push(encoder.encode('Content-Disposition: form-data; name="$content"\r\n'));
	chunks.push(encoder.encode('Content-Type: application/json\r\n\r\n'));
	chunks.push(encoder.encode(JSON.stringify(content)));
	chunks.push(encoder.encode('\r\n'));

	options.files.forEach((file, index) => {
		chunks.push(
			encoder.encode(
				`--${boundary}\r\n` +
					`Content-Disposition: form-data; name="files[${index}].file"; filename="${escapeQuoted(file.path)}"\r\n` +
					'Content-Type: application/octet-stream\r\n\r\n'
			)
		);
		chunks.push(file.bytes);
		chunks.push(encoder.encode('\r\n'));
	});

	chunks.push(encoder.encode(`--${boundary}--\r\n`));

	return {
		body: concat(chunks),
		contentType: `multipart/form-data; boundary=${boundary}`
	};
}

/** Escapes a value for a quoted `Content-Disposition` parameter. */
function escapeQuoted(value: string): string {
	return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function concat(chunks: Uint8Array[]): Uint8Array {
	const size = chunks.reduce((total, chunk) => total + chunk.byteLength, 0);
	const out = new Uint8Array(size);
	let offset = 0;
	for (const chunk of chunks) {
		out.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return out;
}

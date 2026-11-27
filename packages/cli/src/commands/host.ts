// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { loadContext } from './context.js';

/**
 * Prints the instance URL for the configured target to stdout, so a shell can
 * inline it: `curl "$(facet-cli host)/Api/..."`. Prints nothing but the URL —
 * no banner — so a command substitution stays clean. The URL has no trailing
 * slash; a caller appends the path with its leading slash.
 */
export async function runHost(root: string, targetName?: string): Promise<void> {
	const { instanceUrl } = loadContext(root, targetName);
	process.stdout.write(`${instanceUrl.replace(/\/+$/, '')}\n`);
}

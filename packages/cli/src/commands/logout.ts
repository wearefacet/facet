// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { loadContext } from './context.js';
import { removeSession } from '../auth.js';

/** Removes the stored session for the configured instance. */
export async function runLogout(root: string, targetName?: string): Promise<void> {
	const { instanceUrl } = loadContext(root, targetName);
	if (removeSession(instanceUrl)) {
		console.log(`Removed the stored session for ${instanceUrl}.`);
	} else {
		console.log(`No stored session for ${instanceUrl}.`);
	}
}

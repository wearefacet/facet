// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import {
	getAppKey,
	issueAppKey,
	revokeAppKey,
	type AppKeyStatus,
	type IssuedAppKey
} from './apiKeys.js';
import { errorMessage } from '$lib/datasource/bannerError.js';
import * as m from '$lib/paraglide/messages';

/**
 * Reactive app API-key lifecycle state for one app: current key status plus
 * the issue / revoke flows, with loading flags and a single error channel.
 *
 * `refresh` re-reads the status; every write refreshes the status after it
 * settles so the panel agrees with the backend.
 */
export function useAppKeyStatus(getAppId: () => string) {
	let status = $state<AppKeyStatus | null>(null);
	let loading = $state(false);
	let issuing = $state(false);
	let revoking = $state(false);
	let error = $state<string | undefined>(undefined);

	async function refresh(): Promise<void> {
		loading = true;
		error = undefined;
		try {
			status = await getAppKey(getAppId());
		} catch (err) {
			error = errorMessage(err, m.errors_app_key_status());
		} finally {
			loading = false;
		}
	}

	/** Issue (or rotate) the key. Returns the raw key exactly once, or null on failure. */
	async function issue(): Promise<IssuedAppKey | null> {
		if (issuing) return null;
		issuing = true;
		error = undefined;
		try {
			const issued = await issueAppKey(getAppId());
			await refresh();
			return issued;
		} catch (err) {
			error = errorMessage(err, m.errors_app_key_issue());
			return null;
		} finally {
			issuing = false;
		}
	}

	/** Revoke the active key. Returns true when the revoke went through. */
	async function revoke(): Promise<boolean> {
		if (revoking) return false;
		revoking = true;
		error = undefined;
		try {
			await revokeAppKey(getAppId());
			await refresh();
			return true;
		} catch (err) {
			error = errorMessage(err, m.errors_app_key_revoke());
			return false;
		} finally {
			revoking = false;
		}
	}

	function dismissError(): void {
		error = undefined;
	}

	return {
		get status() {
			return status;
		},
		get loading() {
			return loading;
		},
		get issuing() {
			return issuing;
		},
		get revoking() {
			return revoking;
		},
		get error() {
			return error;
		},
		dismissError,
		refresh,
		issue,
		revoke
	};
}

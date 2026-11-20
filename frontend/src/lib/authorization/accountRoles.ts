// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { assignRole, unassignRole, type AccountMutation } from './roleMembership.js';
import type { DataDriver } from '$lib/datasource/driver.js';

/**
 * Write helpers for role membership on `iam.Account` — shared by the
 * assignments page and the role members page. Both read/write the same
 * fields (`roles`, `default_role`), so the PATCH shape has one home.
 */

/** Result of an add/remove computation by `roleMembership`. */
type RoleChange = AccountMutation;

/**
 * Build a single update mutation that sets `roles` and (only when the
 * persisted default must change) `default_role`. The update API deep-merges
 * a plain content-shape object over the current document, so the whole
 * `roles` array is replaced in one go — there is no in-place array op.
 */
export async function patchAccountRoles(
	driver: DataDriver,
	accountId: string,
	roles: string[],
	defaultRole: string | null | undefined,
	currentDefault: string | null | undefined
): Promise<void> {
	const patch: Record<string, unknown> = { roles };
	if (defaultRole !== undefined && defaultRole !== (currentDefault ?? null)) {
		patch.default_role = defaultRole;
	}
	await driver.domain('iam').doctype('Account').doc(accountId).update(patch);
}

/**
 * Compute an add or remove against `accountData.roles` and persist it.
 * `defaultRole` stays untouched unless the change makes the persisted
 * default stale (the `roleMembership` helpers decide).
 */
export async function applyRoleChange(
	driver: DataDriver,
	accountId: string,
	accountData: { roles?: string[]; default_role?: string | null },
	op: 'assign' | 'unassign',
	roleId: string
): Promise<void> {
	const currentRoles = accountData.roles ?? [];
	const currentDefault = accountData.default_role ?? null;
	const change: RoleChange =
		op === 'assign'
			? assignRole(currentRoles, roleId, currentDefault)
			: unassignRole(currentRoles, roleId, currentDefault);
	await patchAccountRoles(driver, accountId, change.roles, change.defaultRole, currentDefault);
}

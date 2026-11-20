// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import type { LayoutData } from '../$types';

/**
 * Domains landing load. The page data is the same shape as the layout
 * data (published domains), so this is a thin pass-through that allows
 * the page to be invalidated independently of the configure layout
 * (e.g. after a draft is created and the published set has not changed).
 */
export const load: PageLoad = async ({ parent }): Promise<Pick<LayoutData, 'domains'>> => {
	const { domains } = await parent();
	return { domains };
};

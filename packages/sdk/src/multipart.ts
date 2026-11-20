// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * The part name for one file: the override when given, else the file's own
 * name, else the server's fallback for a nameless part.
 */
export function filePartName(file: File | Blob, override?: string): string {
	if (override !== undefined && override !== '') {
		return override;
	}
	const name = (file as File).name;
	return typeof name === 'string' && name !== '' ? name : 'upload';
}

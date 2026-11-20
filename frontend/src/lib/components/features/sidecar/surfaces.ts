// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { registerSidecarSurface } from '$lib/surfaces/registry.js';
import CommentSurface from './CommentSurface.svelte';
import AttachmentSurface from './AttachmentSurface.svelte';

/**
 * Sidecar surface registrations. Imported for its side effect — the panel
 * (and stories) import this module so `surface: 'comment'` and
 * `surface: 'attachment'` definitions always resolve to their custom
 * surfaces.
 */
registerSidecarSurface('comment', CommentSurface);
registerSidecarSurface('attachment', AttachmentSurface);

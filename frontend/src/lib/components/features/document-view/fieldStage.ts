// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Registration channel for async field work between a form and its input
 * widgets (B-191).
 *
 * An input widget that stages its value out of band (the secret input today:
 * a stage call round-trips to `/Api/secrets/stage` before the handle reaches
 * the shared values bag) calls the registrar once per attempt with the
 * owning field path and the promise that settles when the attempt lands.
 *
 * The form (`DocumentForm`) awaits every registered promise before it diffs
 * the values bag, so a save never races a stage round-trip, and it stops the
 * save loudly when a field's last attempt was rejected. The latest attempt
 * per field supersedes the previous one — a re-stage or a clear releases the
 * gate.
 *
 * The registrar travels through the template tree as a plain prop, the same
 * way `fieldErrors` does; a widget that never stages simply does not call
 * it.
 */
export type FieldStageRegistrar = (field: string, stage: Promise<void>) => void;

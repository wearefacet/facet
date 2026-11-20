# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Event helper ─────────────────────────────────────────────────────────────
#
# Typed accessor for the in-process event manager that spec_helper installs
# on `Facet::Event::Publisher`. Import/export job specs use it to read and
# clear recorded events between steps.

def event_manager : Facet::Event::InProcessManager
  Facet::Event::Publisher.manager.as(Facet::Event::InProcessManager)
end

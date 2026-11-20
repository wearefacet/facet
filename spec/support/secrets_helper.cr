# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Valid 32-byte master key fixture for specs that construct a full `Config`
# (and for the secrets store those configs back). The secret store fails
# closed on a missing or short key, so every direct construction must carry
# real key material. Defined once here — `spec_helper` requires this file —
# so any spec file compiles standalone, not only inside the full suite.
TEST_MASTER_KEY = "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="

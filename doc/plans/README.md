# Doc plans index

Plans are temporary. A plan retires into the docs it produced.

| Plan                                                                        | Topic                                          |
| --------------------------------------------------------------------------- | ---------------------------------------------- |
| [`artifact-variants.md`](artifact-variants.md)                              | Artifact variants — backend-generated renditions in the flat `artifacts` table (draft — decisions D1–D9 in §8) |
| [`container-release.md`](container-release.md)                              | Container release — backend changes, images, GHCR pipeline (Phases 0–7 green; Phase 8 first release run open — see the progress file) |
| [`db-per-domain-placement.md`](db-per-domain-placement.md)                  | Per-domain database placement (phase target 2)  |
| [`docker-install.md`](docker-install.md)                            | One-command Docker install (dev machines)       |
| [`domain-restore.md`](domain-restore.md)                            | Restore a dropped domain — `Domain::Restore` feasibility study (draft — seven open decisions in §8) |
| [`documentation/`](documentation/)                                  | Documentation website — whole-doc plan split into dispatchable work packages (see [`documentation/README.md`](documentation/README.md)) |
| [`longtext-mermaid.md`](longtext-mermaid.md)                                | Mermaid diagrams in longtext markdown (planned — the skill corpus already documents the behaviour) |
| [`passkey-mfa-channel.md`](passkey-mfa-channel.md)                          | Passkey (WebAuthn) as an MFA channel — feasibility study, five open decisions in §8 |
| [`qa-bugs/`](qa-bugs/)                                              | F-series QA findings (naive sweeps 2026-11-17 through 2026-11-20) with per-finding verification (see [`qa-bugs/INDEX.md`](qa-bugs/INDEX.md)) |
| [`role-templates.md`](role-templates.md)                    | Role templates — compose a role from reusable concern bundles; rights + scope merge at authoring time, drift check for compliance (draft — seven open decisions in §8) |
| [`structure-readability.md`](structure-readability.md)                      | Source structure readability refactor          |
| [`test-baseline-restore.md`](test-baseline-restore.md)                      | Per-example test baseline restore — snapshot instead of re-seed (draft — precursors implemented, see §8) |

Retired plans (implemented 2026-10/11, removed 2026-11-07): webhook SSRF rules → [`backend/webhook.md`](../backend/webhook.md); reference chips → [`frontend/markdown-editor.md`](../frontend/markdown-editor.md); `@facetapp/sdk` / `@facetapp/chat` → [`packages/`](../packages/); B-83 tool-trace, Run 35 F03 fixes — shipped, no doc.

The code quality and dedup pass (implemented 2026-09-28, removed 2026-11-17) produced shared helpers that the concern docs describe: `HTTP::Helpers.require_csrf` and the `HTTP::Helpers`/`HTTP::Gates` split (`backend/http-layer.md`), and `Doctype::DefinitionGate` with its version gate (`backend/doctype-system.md`). Its three undecided items carry on with new evidence in [`structure-readability.md`](structure-readability.md) §10.

The markdown inline-references plan (implemented and green 2026-10-31, removed 2026-11-08) retired into [`frontend/markdown-editor.md`](../frontend/markdown-editor.md), [`frontend/sidecar-panel.md`](../frontend/sidecar-panel.md), [`backend/notifications.md`](../backend/notifications.md), [`backend/links.md`](../backend/links.md), and [`backend/search.md`](../backend/search.md). One open question survives it: should a mention grant the mentioned account read access to the host document? Today the `comment_mention` notification fires regardless of host read access, and its title carries the host display name — the plan's decision D3 accepted the leak.

The F-series QA findings live in [`qa-bugs/`](qa-bugs/INDEX.md): the naive sweep of 2026-11-17 (verified against `2c2086e8`), the naive F01–F10 sweeps of 2026-11-18 (verified against `c782d339`) and 2026-11-19 (verified against `a8520dee`), and the naive F01–F10 sweep of 2026-11-19/20 (verified against `1b7bf906`, open pending triage).

The release-readiness audit findings live in [`audit/summary.md`](audit/summary.md).

The agent-experience findings and their per-finding verification live in [`debug/agent-experience-findings-verification.md`](debug/agent-experience-findings-verification.md).

The E2E program plans are implemented; the harness and the scenario suite they produced are documented in [`e2e/README.md`](../../e2e/README.md).

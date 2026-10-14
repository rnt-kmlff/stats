# Processes preview design and verification

## Objective and authorized step

Implement a local Processes view for ChatGPT/Codex and current-user Node, Python and build-tool trees, with bounded memory history and configurable notifications. The owner requested implementation, building and testing on their Mac. Publication of the feature branch is needed for the Xcode build runner; no merge is authorized. Activation for this local development test retains the approved ad hoc signing boundary and a rollback artifact.

Impact: Material (new process sampling, history, classification and alerts). Runtime: a preview from `codex/processes-view`; identify the exact commit and artifact receipt before installation. Keep the upstream source, licence and baseline artifact intact.

## Design

- Public read-only libproc calls, current-user processes only. Identity uses PID and start time; footprint is `ri_phys_footprint`. A second identity check rejects a reused PID during the read. No task ports, privileged helper, process controls, command arguments, environment variables or memory-content reads.
- Five-second sampling on one serial utility queue inside Stats. Sampling respects the Processes toggle, the global Stats pause and sleep. Wake/missing-sample gaps reset sustained-alert timing and invalidate growth across gaps.
- Classify outer ChatGPT/Codex bundles and standalone Codex; count external Node/Python/build trees separately. A process belongs to one group. Executable names are heuristic evidence, not proof of build activity or a specific conversation. Group values are sums of process footprints and can differ from Activity Monitor accounting.
- At most 20 current groups and 512 footprint reads per sample; explicitly flag a reached limit. At most 544 retained series, each with at most 721 samples over one hour. Process exits preserve bounded history; unavailable data is a gap, never zero. History stays in RAM and clears on app exit. Preferences contain rules only, with at most 20 lifetime-specific overrides.
- Alerts default off. Editable defaults: app budget 8 GiB, job budget 4 GiB, growth 1 GiB over five minutes, 15-second hold and 300-second cooldown. These are notification thresholds, not hard RAM caps or guarantees. Child processes alert only with an explicit custom rule. A sustained breach alerts once per incident, rearms below 90% of budget and respects cooldown. Settings revisions discard obsolete queued events.
- Alert authorisation is checked before scheduling. Foreground presentation applies to this feature's notification namespace. The view includes a safe test notification and delivery-status readback. There is no automatic process termination, launcher, independent service, schedule, telemetry upload or remote activation.

## Mandatory scorecard

| Criterion | Status | Evidence / required follow-up |
| --- | --- | --- |
| Scope and data meaning | Met by design | Explicit grouping/footprint labels; no chat attribution claims or process controls. |
| Privacy and least privilege | Met by design | Current-user libproc reads; no secret-bearing process arguments or persistent histories. Review final diff. |
| Identity, gaps and alerts | Focused tests passed | 29 deterministic fixtures pass locally and cover restart/PID reuse, denial, partial samples, timing, flapping, recovery, growth and history bounds. |
| Reproducibility | Met by design | Pinned actions, exact-head build receipt, checksum and signature checks; no credentials in build workflow. |
| Capacity and operation | Preview tested; final regression pending | Five live read-only scans on the development Mac averaged 6.5 ms (max 7.9 ms), with complete readings and no sampling limit. First exact preview compiled, passed the 166 upstream tests, displayed live groups/individual history and delivered one sustained-threshold alert without added load. A focused-field reset display issue was fixed; repeat reset, pause, persistence and footprint checks on the final candidate before completing activation. Private receipts only. |
| Recovery and rollback | Prepared | Keep baseline installer/artifact and private preference backup. Replace only the owned Stats app at a clean quit boundary. |
| Signing | Explicit limitation | Ad hoc signed development preview, not Apple-notarised. Never disable security controls or remove quarantine to force a launch. |

Readiness: Conditional for the scoped build and local preview test after focused tests and source review pass. Full app compilation uses the GitHub macOS runner because this Mac has Command Line Tools rather than full Xcode. Merge remains a separate owner decision.

## Validation plan

Run `python3 scripts/test-processes.py`, the upstream mocked SMC/helper suite, and the exact-head arm64 Xcode build. Check changed Swift syntax and sampler types locally. On the Mac, verify the source-bound signature, single running app, saved RAM bar/remote settings, live groups and children, bounded history, settings persistence, pause/resume, normal limits after temporary alert tests, and notification status. Capture only compact private counts/measurements; no public machine identities, process histories or screenshots.

# Process roles, age and attribution coverage

Impact: Material (process classification and presentation of identity/coverage). Owner requested implementation, building and a local Mac test on 15 October 2026. Prepare and publish an isolated feature preview from `codex/process-details`, based on the reviewed merge of chat attribution. Merge remains a separate Rinat decision. The existing ad hoc development-build approval and requested Mac preview test cover the same local signing/installation boundary.

## Objective and meaning

Make retained app memory understandable by showing executable-based App, Renderer, Server / CLI, Helper, Local job and Other roles, a measured RAM/count breakdown by role, and process age. Roles are descriptive heuristics from the already collected executable path/name, never proof of a specific chat or of a running build. Server / CLI deliberately includes standalone Codex because this collector does not read arguments to distinguish modes. Groups use Group; their age is their root process's age. Helper descendants without a recognized executable remain Other rather than a guessed role.

Age comes from the existing OS process start timestamp, including microseconds, rather than time since Stats discovered it. Rows preserve the last observed age while paused, unavailable or exited. A missing/invalid start or future start after wall-clock rollback is unavailable. Age is descriptive wall-clock elapsed time and may shift with a system clock adjustment; histories and alert holds still use monotonic time. PID/start-time identity keeps reused PIDs separate.

When chat linking is enabled, show both linked process count / observed process count and linked known footprint bytes / all observed known footprint bytes. Deduplicate identities before role and chat summaries. Keep conflicting duplicate observations unknown. Explicitly state missing footprints, observed-subset limits and tag scan limits; an empty/zero/overflow denominator is unavailable. A percentage with missing readings covers only known bytes and is not whole-app, whole-chat or complete machine attribution. Pausing clears the current role/coverage summaries instead of implying zero RAM. Group and child rows are never both added to totals.

No new process APIs, argument/environment keys, local databases, app control connections, logs, network services or permissions are added. Existing 64 tag reads, 20 name lookups, five-second serial sampling, bounded in-memory history and alerts retain their reviewed contracts. Existing preferences migrate without new fields. Remote remains off; no killing or automatic intervention. No private process lists, chat names/IDs, screenshots or receipts go into Git or public CI.

## Continuing chat-link investigation

The current official app-server background-terminal listing is experimental and its OS PID may be null; it does not map shared renderer heaps. The installed host has internal webContents-to-OS-PID and diagnostic facilities, but no supported external read-only chat/renderer association was established. Do not attach to the desktop's app-server connection, enable debug ports, patch the host app or read heap/transcript payloads for this preview. A future cooperative host export must identify PID plus process start, view/worker identity, owner chat IDs, sharing and lifecycle. Whole shared heaps must remain shared even with such a map. Terminal ownership alone does not assign app-server or renderer memory. [Official background-terminal API](https://learn.chatgpt.com/docs/app-server#clean-background-terminals).

## Mandatory scorecard

| Criterion | Status | Evidence / next check |
| --- | --- | --- |
| Scope, owner and authority | Met for publication | Requested display/measurement semantics only; Rinat owns merge. Existing local preview/rollback boundary retained. |
| Identity and false attribution | Met for publication | Roles never create chat ownership. Fourteen new fixtures cover role ambiguity, age/PID reuse, byte versus process coverage, missing data, duplicate conflicts and overflow; 76 focused tests passed. |
| Privacy and least privilege | Met for publication | Reuses already sampled path/start/footprint/tag/name fields. No additional collection or persistence. Diff/private-data review required before push. |
| Reproducibility and integration | Partial for activation | Core suite and Swift view parsing pass locally. Exact-head full arm64 build, lint/i18n and synthetic upstream regression suite remain before activation. |
| Capacity and operation | Partial for activation | Same scan/history caps and serial cadence; small bounded aggregation over the observed sample. Final role/age/coverage, missing/off/paused states, own footprint and single-app checks remain on the Mac. No stress test required. |
| Recovery and rollback | Met by design | Preserve the exact prior app, preference backup and private receipt. Replace only after Stats quits; restore prior artifact if scoped checks fail. No unattended upstream update. |
| AI/notifications | Met by design | Plain local labels only; no model requests or injected tool authority. Existing notification thresholds/text remain process-only and unchanged. |

Readiness: Ready for publication and exact-head CI; Conditional for the requested bounded local preview after successful build and signature integrity checks. Full release/notarization, reboot/login tests, universal enforcement and whole-chat accounting are outside this preview and are not claimed.

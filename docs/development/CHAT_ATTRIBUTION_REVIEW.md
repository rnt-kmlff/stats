# Codex chat labels and shared-policy adoption

Impact: Material (repository instruction adoption, process identity/attribution and a new local metadata read). Owner requested both changes on 14 October 2026. Next steps are prepare, publish for review, build and a bounded local preview test; merge remains a separate Rinat decision. The existing installed preview is preserved until the exact candidate passes its applicable checks.

## Objective, alternatives and limits

Adopt the unchanged common GitHub review/release policy v1.0 in AGENTS.md, a portable policy copy and a PR template. These are human/agent instructions, not new GitHub branch protections, privileges or unattended release authority.

Associate directly tagged current-user local jobs with their Codex chat titles. Show their measured process footprints without pretending that shared Electron renderers, app-server heaps or untagged helpers belong to a particular chat. No division by recency, cwd, active status or equal shares. Per-chat sums cover linked processes only, never the whole chat's memory. Existing process grouping, memory history and alert budgets retain their meaning.

The official app-server documentation exposes an experimental thread/backgroundTerminals/list method, but its processId is an internal ID and osPid may be null. The desktop app's existing stdio connection is not a supported external monitor endpoint. Do not attach to its control channel, launch another app-server, resume chats or send messages to obtain attribution. [Official reference](https://learn.chatgpt.com/docs/app-server#clean-background-terminals).

An instrumented launcher/manifest is an alternative for stronger ownership evidence, but a common launcher remains deferred. Cwd/name heuristics were rejected because chats share projects and workers. A bounded local pilot established that shell jobs inherit CODEX_THREAD_ID/CODEX_SESSION_ID, while the shared renderers and most service workers do not. This release offers partial visibility and labels the remainder explicitly.

## Local metadata contract and privacy change

Chat linking is an explicit switch, off by default and backwards-compatible with saved preview settings. When off, do not inspect process argument/environment buffers or open Codex metadata. No conversation messages, histories, logs, auth/config files or remote services are used.

When enabled, the current-user collector may request a bounded KERN_PROCARGS2 buffer only for already watched process identities. This is a deliberate change from the first Processes preview, which read no arguments or environments. macOS returns a combined buffer that can contain unrelated secrets; skip arguments, extract only exact CODEX_THREAD_ID/CODEX_SESSION_ID UUID values, never stringify/log/export other bytes, and wipe the transient allocation with memset_s before release. Denial, malformed/truncated data, conflicting IDs, PID reuse and scan limits mean Unlinked, never guessed ownership. Tags are local association evidence, not authentication or a security boundary.

Read only id/name for discovered UUIDs from the local ~/.codex/state_5.sqlite metadata database using read-only SQLite, bounded busy time and cache, prepared indexed queries and bounded title strings. The legacy column named title can contain opening-prompt text and is deliberately never queried. It is an undocumented local schema: failure or schema drift leaves the UUID label/title unavailable without repair, migration or fallback to transcripts. No Codex records are changed and no SQL writes or migrations run; SQLite may coordinate normal read locks. Local titles/IDs appear only in the app's in-memory view, not public logs/receipts, preferences or CI fixtures. Turning linking off clears them. Notifications keep process-only text and never include chat names/IDs, so this feature does not persist those labels in Notification Center.

At most 512 watched processes, 64 kernel tag reads and 20 title lookups per tick; one transient buffer up to 1 MiB, a 512 KiB SQLite page cache, bounded label collections and five-second serial sampling. Re-check process start identity after a tag read. Do not attribute descendants solely from ancestry; inherited tags must actually be present. Groups get a chat label only if every member has the same verified tag. Chat totals deduplicate process identities and show missing footprint data explicitly. Graphs remain process history, with current chat labels rather than retrospective whole-chat accounting.

## Mandatory scorecard

| Criterion | Status | Evidence / next check |
| --- | --- | --- |
| Shared policy/owner and authority | Met by design | Copy of approved v1.0; Rinat remains merge/activation owner. No branch protection, scheduler or auto-deployment installed. |
| Scope, identity and error cost | Met for publication | Conservative tagged-only attribution; shared heaps stay unlinked. The 62-test suite covers conflicts, mixed groups, duplicate counts, missing data, PID identity and ownership changes. |
| Privacy and least privilege | Met for publication | Exact parser/source reviewed; two UUID keys only, wiped allocation and name-only read-only SQL. Tests verify disabled access, missing metadata, schema drift, busy reads and no opening-prompt fallback. Titles are plain bounded labels. |
| Validation/reproducibility | Partial for activation | 62 focused/regression tests pass locally, including owned synthetic processes and disposable databases; Swift view parsing/type checks and policy-copy equality pass. Exact-head full app CI build/lint/i18n and final UI tests remain before activation. |
| Capacity/integration | Partial for activation | Five enabled read-only scans stayed below 25 ms in the bounded pilot. A capped owned Node fixture was linked to its actual local chat. No stress workload or whole-chat accounting claim. Final UI/own-footprint checks remain. |
| Recovery/upgrade/rollback | Met by design | Missing old preference defaults to off; no Codex mutations. Preserve installed preview artifact/preferences. Disable links to return to process-only mode. |
| Ownership/monitoring and AI | Met by design | Rinat owns release decisions. Titles are untrusted plain labels, never instructions or tool authority. No model/API, autonomous action or automatic killing. |

Readiness: Ready for publication of the reviewed feature branch and exact-head CI build; Conditional for the bounded local preview experiment after the build/signature checks. Final runtime evidence and exact candidate receipts remain private. No merge or broader rollout is authorized by passing checks.

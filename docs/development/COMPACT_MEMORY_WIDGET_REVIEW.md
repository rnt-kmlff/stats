# Compact memory menu-bar display

Impact: Material (new aggregate display and cache/freshness contract). Requested on 16 October 2026: keep helper integration on hold; combine a pressure dot, current ChatGPT/Codex RAM and the existing swap indicator. Base is merged PR #2 at c67350de1fe5818f84fb9500122c3606d60e584e, excluding held PR #3.

Use the existing RAM State dot plus Text in one menu-bar item, ordered dot then text. Proposed local template: `GPT $chatgpt.used · $swap.used`. The new token uses the existing five-second Processes sampler; pressure and swap keep their existing RAM reader and formatting. No extra process scan, helper instrument, host change, permissions, model action, telemetry or automatic killing. The baseline default text template is unchanged; activation selects the requested template locally.

The new number sums unique observed process identities in established assistant app-family groups (ChatGPT/Codex roots, renderers, servers and helpers), including compressed footprint as reported by the OS. Separate local-job groups stay excluded. This is a sum of observed process footprints, not a claim to physically deduplicate OS shared pages or allocate RAM to chats. The existing grouping and sample/read bounds remain intact. No PID/name/chat data crosses the in-process Kit bridge: only aggregate bytes, state and monotonic sample time. Nothing is persisted or added to remote/widget exports.

A failed/incomplete enumeration, all unavailable readings or overflow yields `—`; an observed subset is prefixed `~`. An unambiguous complete empty assistant sample yields zero. A fifteen-second age limit prevents an abandoned sample looking current. Pause/off/sleep clear the app number through an in-process notification even when RAM readers stop. Pressure uses the existing green/yellow/red mapping, with accessible text and a tooltip; no visible pressure word. The text tooltip explains the full app name, partial/stale state and grouping scope. Existing swap remains the last RAM-module reading under normal pause semantics.

Alternatives: scraping the popup top-eight process list could omit a smaller app, and a second process sampler would duplicate work. Reusing the established full watched subset avoids both. More exact per-chat ownership remains deferred and unproven shared memory stays unassigned.

| Criterion | Status | Evidence / gate |
| --- | --- | --- |
| Scope and authority | Met for prepare/publication | Requested Stats-only widget change and local verification. Rinat remains merge owner; no merge implied. PR #3 held separately. |
| Meaning and identity | Met by design | Existing app/job grouping, unique PID/birth identities; partial/unavailable/overflow/zero contracts. Synthetic regression checks required. |
| Privacy and permissions | Met by design | Aggregate-only RAM cache; no persistence, extra process access or remote export. No chat mapping change. |
| Reliability/recovery | Met by design | Thread-safe cache, monotonic expiry, pause/off/sleep invalidation and normal restart; no automatic intervention. |
| Reproducibility | Partial | Focused tests, exact-head arm64 build, lint/i18n, signature/source/checksum and final UI remain before activation completes. |
| Capacity | Met by design | Reuses the existing serial sampler; constant-size cache and existing text draw cadence. Bounded live check required. |
| Activation/rollback | Partial | Preserve existing app/preferences/private receipt; verify combined live display, existing swap, settings and single runtime after replacement. |
| AI and alert authority | Met | No AI/tool/schedule change; current alerts and thresholds remain intact. No common launcher. |

Readiness: Ready for preparation/publication after focused checks; Conditional for local development preview pending exact-head checks and bounded UI verification. Long soak, reboot/login, vendor/helper integration and notarized distribution are outside this change. Detailed runtime receipts/screenshots stay private; synthetic fixtures only in Git/CI.

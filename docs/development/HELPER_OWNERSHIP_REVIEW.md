# Cooperative helper association export

Impact: Material (new private metadata producer/reader and shared association semantics). Owner requested PR #2 merge and a helper-ownership prototype on 15 October 2026. Prepare an isolated feature branch, publish for exact-head CI and run a bounded local development preview with an owned cooperating helper. No merge or automatic integration of installed helpers is authorized by this request. Preserve the existing tested app/preferences for rollback.

## Objective, alternative and limits

Expose which chats a helper has seen, beside its measured footprint. Do not invent an exclusive heap owner. The prototype SDK accepts only normalized chat UUIDs from the helper's already validated request metadata. It supports Python and Node, current-user macOS only. It is not a proxy and does not read tool arguments, host control channels, transcripts or heaps. Existing installed host/plugin helpers remain unmodified; actual adoption requires their own explicit integration. A host-side PID/view/chat export remains necessary for renderer associations, and shared renderer/server heaps still cannot be split accurately. Terminal listings alone cannot establish that map. [Official reference](https://learn.chatgpt.com/docs/app-server#clean-background-terminals).

Every record and label is shared even with one chat. Exported helpers are excluded from direct tag assignment while the association is observed; their bytes remain in shared/unlinked RAM and tagged coverage never increases from this source. Helper association totals count unique member processes only. All-member helper groups can display their union; mixed app groups remain shared/unlinked. Existing local-job alert defaults still cover a standalone helper group; no threshold, process-control or notification-content authority changes.

## Metadata/privacy and identity contract

The SDK writes only the fixed ten-field version-1 protocol in its current-user mode-0700 namespace, with mode-0600 regular files. It stores UUIDs but no names, prompts, arguments, tokens or environment data. This is a deliberate new local persistence boundary; schema/retention and opt-out are documented in [the SDK guide](../../tools/helper_ownership/README.md). Local chat names remain RAM-only and are excluded from notifications/public evidence. Same-user records are association evidence, never authentication or permission to act. Unknown content is data, not instructions.

Identity uses PID, UID and the exact kernel birth seconds/microseconds, checked before/after the reader. The Node bridge derives its direct parent from the kernel rather than accepting a target PID. Directory/file descriptors, no-follow opens, owner/mode/type/link/size checks and atomic replacement defend against path tricks and partial writes. Wrong schema, extra fields, exclusive claims, mismatched birth, invalid IDs or dates fail closed. File disappearance/replacement and temporary scan gaps retain previously observed shared associations in a bounded lifetime cache until the kernel establishes exit/reuse; unobserved identities are not emitted/counted. This never becomes a guessed exclusive owner. Off clears the cache/labels and adds no export-file I/O; existing producers are independently opt-in and are not controlled by Stats.

No heartbeat, common job launcher, monitor schedule, privileged service, automatic killing, telemetry upload, host patch or debugging endpoint. Each new chat association triggers one small update, first eight IDs plus overflow; repeated IDs do not write or spawn. Producer directory count (128) is advisory against a simultaneous-start race. Consumer enumeration (128), file reads (32), file bytes (8 KiB), per-record IDs (8) and cached process identities (128) are independent bounds. Name lookup remains 20 across tags and helpers combined. Crash remnants are inert unless process birth matches; normal shutdown removes only its own instance, and cleanup is not silently applied to unrelated files.

## Mandatory scorecard

| Criterion | Status | Evidence / next check |
| --- | --- | --- |
| Scope/owner and authority | Met for publication | Requested prototype and local owned-helper experiment; Rinat remains merge owner. No installed helper configuration is rewritten. |
| Meaning, identity and false attribution | Met for publication | Shared-only protocol, exact birth matching and separate tagged coverage. Tests cover wrong identity, lifetime union, disappearance, duplicate counting and source exclusion. |
| Privacy/least privilege | Met for publication | Fixed UUID-only producer schema, private namespace, no-follow/size/mode/link checks; disabled reader has no file access. Same-user evidence is not a security boundary. |
| Failure/recovery | Met for publication | Non-fatal export failures, atomic retry, bounded capacity, safe normal-close instance check, inert crash records and settings compatibility. |
| Reproducibility/validation | Partial for activation | 91 Swift and 12 exporter tests pass locally, including the untagged Node bridge. Exact-head arm64 app build, upstream mocks, lint/i18n and final UI tests remain. |
| Capacity/integration | Partial for activation | Event-driven producer, bounded reader and unchanged five-second serial sampler. Owned Mac pilot must verify sharing, retained idle association, off/exit behavior and own footprint before completing local activation. |
| Rollback and monitoring | Met by design | Preserve prior app and preferences. Disable the reader/close the owned producer to return to the prior view. Private receipts only. No universal enforcement claim. |
| AI/permissions and alerts | Met by design | No model/API action; labels cannot drive tools. Existing process-only alert text/budgets remain intact. |

Readiness: Ready for publication and exact-head CI; Conditional for the bounded local prototype after required build/signature checks. No long-soak, reboot/login, broad plugin adoption, notarized release or whole-chat allocation claim.

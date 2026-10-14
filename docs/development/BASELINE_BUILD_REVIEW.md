# Fork baseline build review

## Objective and exact scope

Prepare an unchanged Stats 3.0.21 baseline from upstream revision `ac791a10a53b0457a467e7ee341b512ad9413e03` in this fork, test it on a GitHub macOS runner, and produce an arm64 local-development artifact. Application source remains unchanged. Individual-process memory features will be a separate reviewed change.

Impact: Material because this adds a build/artifact workflow. The owner authorized the fork, baseline build, installation and test sequence. No merge, privileged-helper installation, remote-monitoring activation or new application functionality is implied.

## Review scorecard

| Mandatory criterion | Status | Evidence |
| --- | --- | --- |
| Exact source and candidate identity | Met by design | Source revision is pinned; the workflow rejects application-source differences and binds the artifact receipt to its candidate SHA. |
| Least privilege and private data | Met by design | Read-only repository permissions, no secrets or developer certificates, pinned official actions, public upstream source only. |
| Tests and artifact verification | Pending run | Upstream mocked SMC/helper tests, arm64 build, version check, signature verification and ZIP hash. |
| Signing boundary | Explicit limitation | Ad hoc development signature only; no Developer ID certificate or notarization. Do not represent the artifact as a notarized upstream release or bypass macOS security controls. |
| Runtime verification and rollback | Pending local test | Retain the official release and preferences; inspect the exact candidate before replacement; confirm RAM/swap/process readings, warning setting and remote-disabled state. |
| Scope preservation | Met by design | No app-source edits, automatic process termination, credentials, source-data exports or telemetry changes. |

Readiness: Conditional for the authorized baseline build and local test. A failed source, test, signature or security check blocks installation until reconciled. No stress test should exhaust memory.

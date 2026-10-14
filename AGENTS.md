# Stats fork working agreements

- This is a personal fork of exelban/stats. Preserve the MIT licence and upstream attribution. Keep private machine data, credentials, screenshots, monitoring histories and receipts out of Git and public CI.
- The initial baseline is upstream v3.0.21 at ac791a10a53b0457a467e7ee341b512ad9413e03. Application source remains unchanged during the baseline build and test.
- Develop scoped changes on isolated feature branches. Review the exact diff and applicable tests before publication. The human owner approves merge and exact-version runtime activation separately; do not use automatic merge or deployment to bypass approval.
- Memory/process features need an impact review, bounded synthetic tests, false-alarm handling, privacy, interruption/recovery and upgrade compatibility. Do not automatically kill apps or install a privileged helper.
- Baseline build: .github/workflows/fork-baseline.yml. Its artifact is an ad hoc signed local-development build, not a Developer ID notarized release. Preserve the official installer for rollback and never bypass macOS security controls.
- Remote monitoring stays disabled. Keep the instructions-first memory guardrails; a common launcher remains deferred.

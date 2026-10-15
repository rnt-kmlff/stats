# Shared helper association prototype

This opt-in SDK lets a cooperating macOS Python or Node helper report chat UUIDs it has seen. It is an association feed, not authentication or proof that a chat owns the helper heap. Every record says `sharing: shared`, including a helper that has seen one chat. Stats keeps the footprint in shared/unlinked RAM and never adds it to tagged per-chat totals or tagged coverage.

The prototype includes a Stats reader and a small owned demo. It does not instrument installed ChatGPT/Codex helpers automatically, replace plugins, attach to the host app, enable debugging or launch a server/daemon. A real helper must explicitly integrate this API at its existing request-metadata boundary. Existing shared renderer/server heaps remain shared.

## Integrating a cooperating helper

Create one exporter per process, then pass only the normalized UUID already established by its request context. Do not pass prompts, messages, tool arguments, auth/config, environment dumps or titles. A malformed/missing ID or export failure must not fail the helper's normal request.

```js
import { HelperOwnershipExporter } from './stats_helper_ownership.mjs';
const associations = new HelperOwnershipExporter();
// In the existing handler, after validating the caller's metadata:
associations.observeChat(validatedChatId); // false means unavailable; continue normally
// During the helper's own clean shutdown:
associations.close();
```

```python
from stats_helper_ownership import HelperOwnershipExporter
try:
    associations = HelperOwnershipExporter()
except OSError:
    associations = None
# At the helper's existing request-context boundary:
if associations is not None:
    associations.observe_chat(validated_chat_id)
# On clean shutdown (also registered with atexit):
if associations is not None:
    associations.close()
```

The Node adapter uses the included Python bridge with `/usr/bin/python3` by default to read its direct parent's kernel identity and publish safely. It accepts no arbitrary target PID. This small subprocess runs only on an association change, with a one-second timeout and bounded input/output; repeated calls for a known chat do not spawn or write. Python publishes its own kernel identity directly. There is no background heartbeat. Follow the local memory guardrails for the actual helper workload.

## Local protocol and limits

Default directory: `~/Library/Application Support/Stats Helper Ownership/v1`. The private parent and v1 directory must be current-user owned, mode 0700, and not symlinks. Each regular record is mode 0600, has one hard link, and is named `PID-startSeconds-startMicroseconds.json`. Writes replace a small owned temporary file atomically through directory descriptors; no unknown paths are read or followed.

Fields are `version` (1), `instanceId` (UUID), `sharing` (`shared`), `pid`, `uid`, `startSeconds`, `startMicroseconds`, `chatIds` (up to eight canonical UUIDs), `overflow` and `writtenAt` (Unix seconds). Extra fields, wrong versions, exclusive claims, malformed IDs, impossible times and wrong UID/birth are rejected by Stats. No chat title/content is stored. Titles are looked up only through the already reviewed local name-only contract, within the same combined 20-name budget, and remain in RAM/never in notifications.

The SDK keeps its first eight distinct chat IDs for the process lifetime and marks overflow without forgetting earlier IDs. A helper can retain earlier chat state, so an idle association remains shared; it is not expired by a heartbeat timeout. Normal shutdown removes only that instance's record. A crash can leave an inert file: Stats ignores it unless PID plus exact birth still match an observed live process. The SDK's 128-entry directory check is advisory under simultaneous starts and fails closed when full; it does not silently delete old evidence. The reader independently limits directory enumeration to 128 entries, file reads to 32 per sample, records to 8 KiB and in-memory lifetime associations to 128 processes. No full-directory sort or unbounded read occurs.

Stats labels these as shared, seen-during-lifetime associations. It retains observed associations in its bounded cache while the same process remains in the observed sample, even if the file is removed/replaced, so a disappearing export cannot turn a known shared helper into an allocated per-chat total. A temporarily unobserved identity is retained in the bounded cache until the kernel establishes exit/reuse; it is not emitted or counted outside the observed sample. A partial process scan still reduces reported coverage. Disabling chat links/helper reading clears the labels/cache and performs no export-file reads. This does not stop an independently integrated SDK producer; remove/close that producer separately. Unclean records can be reviewed/removed manually after the corresponding helper has exited.

## Bounded local demo

After building the matching Stats preview, enable Link Codex chats and Use shared helper associations in Processes. Start `node --max-old-space-size=64 tools/helper_ownership/demo.mjs` using an existing Node runtime. It prints only readiness/PID. Send JSON lines with `chatId` set to a test UUID; send a second UUID to demonstrate sharing. Send `{"close":true}` to end cleanly. The demo is an owned fixture, not a proxy for other tools. Keep actual runtime records out of Git and public CI.

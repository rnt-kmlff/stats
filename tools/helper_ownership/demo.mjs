// A small owned integration fixture, not a proxy for installed tools.
import readline from 'node:readline';
import { HelperOwnershipExporter } from './stats_helper_ownership.mjs';

const exporter = new HelperOwnershipExporter({ applicationSupport: process.argv[2], python: process.argv[3] });
console.log(JSON.stringify({ ready: true, pid: process.pid }));
const lines = readline.createInterface({ input: process.stdin });
lines.on('line', line => {
  if (line.length > 4096) { console.log('{"ok":false}'); return; }
  try {
    const request = JSON.parse(line);
    if (request.close === true) { exporter.close(); lines.close(); return; }
    const ok = exporter.observeChat(request.chatId);
    console.log(JSON.stringify({ ok, status: exporter.lastStatus }));
  } catch { console.log('{"ok":false}'); }
});
lines.on('close', () => { exporter.close(); process.exit(0); });

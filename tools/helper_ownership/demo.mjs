// A small owned integration fixture, not a proxy for installed tools.
import readline from 'node:readline';
import { HelperOwnershipExporter } from './stats_helper_ownership.mjs';

const exporter = new HelperOwnershipExporter({ applicationSupport: process.argv[2] });
console.log(JSON.stringify({ ready: true, pid: process.pid }));
const lines = readline.createInterface({ input: process.stdin });
lines.on('line', line => {
  if (line.length > 4096) { console.log('{"ok":false}'); return; }
  try {
    const request = JSON.parse(line);
    if (request.close === true) { exporter.close(); lines.close(); return; }
    console.log(JSON.stringify({ ok: exporter.observeChat(request.chatId) }));
  } catch { console.log('{"ok":false}'); }
});
lines.on('close', () => { exporter.close(); process.exit(0); });

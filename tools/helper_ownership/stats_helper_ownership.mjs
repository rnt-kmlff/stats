// Cooperative request metadata only. No interception, tool arguments or host changes.
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export class HelperOwnershipExporter {
  constructor({ python = '/usr/bin/python3', applicationSupport } = {}) {
    this.python = python;
    this.applicationSupport = applicationSupport;
    this.instance = randomUUID();
    this.pid = process.pid;
    this.chats = [];
    this.overflow = false;
    this.dirty = false;
    this.published = false;
    this.closed = false;
    this.lastStatus = "not_published";
    this.onExit = () => this.close();
    process.once('exit', this.onExit);
  }
  observeChat(value) {
    if (this.closed || process.pid !== this.pid || typeof value !== 'string' || !UUID.test(value.toLowerCase())) return false;
    const id = value.toLowerCase();
    if (!this.chats.includes(id)) {
      if (this.chats.length < 8) { this.chats.push(id); this.dirty = true; }
      else if (!this.overflow) { this.overflow = true; this.dirty = true; }
    }
    if (!this.dirty && this.published) return true;
    const result = this.publish(false);
    if (result) { this.published = true; this.dirty = false; }
    return result;
  }
  publish(close) {
    try {
      const args = [fileURLToPath(new URL('./stats_helper_ownership.py', import.meta.url)), '--parent-export'];
      if (this.applicationSupport) args.push(this.applicationSupport);
      const child = spawnSync(this.python, args, {
        input: JSON.stringify({ instanceId: this.instance, chatIds: [...this.chats].sort(), overflow: this.overflow, close }),
        encoding: 'utf8', timeout: 1000, maxBuffer: 2048, windowsHide: true
      });
      if (child.error) { this.lastStatus = child.error.code === 'ETIMEDOUT' ? 'bridge_timeout' : 'bridge_unavailable'; return false; }
      if (child.status !== 0) { this.lastStatus = 'bridge_exit'; return false; }
      const result = JSON.parse(child.stdout);
      if (result.ok !== true) { this.lastStatus = 'export_rejected'; return false; }
      if (result.identity?.pid !== process.pid || result.identity?.uid !== process.getuid()) { this.lastStatus = 'identity_mismatch'; return false; }
      this.lastStatus = 'published';
      return true;
    } catch { this.lastStatus = 'bridge_response_unavailable'; return false; }
  }
  close() {
    if (this.closed || process.pid !== this.pid) return;
    if (this.published) this.publish(true);
    this.closed = true;
    process.removeListener('exit', this.onExit);
  }
}

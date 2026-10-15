import importlib.util
import json
import os
import pathlib
import stat
import tempfile
import select
import subprocess
import sys
import unittest
from unittest import mock

MODULE = pathlib.Path(__file__).resolve().parents[2] / 'tools/helper_ownership/stats_helper_ownership.py'
spec = importlib.util.spec_from_file_location('ownership', MODULE)
ownership = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ownership)
A = '1000000a-0000-0000-0000-000000000001'
B = '1000000b-0000-0000-0000-000000000002'


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='stats-owned-export-test-')
        self.base = pathlib.Path(self.temp.name)
        self.exporter = ownership.HelperOwnershipExporter(self.base)

    def tearDown(self):
        self.exporter.close()
        self.temp.cleanup()

    @property
    def record(self):
        return self.base / 'Stats Helper Ownership/v1' / self.exporter.filename

    def test_disabled_and_invalid_observation_create_no_files(self):
        self.assertFalse(self.exporter.observe_chat({'prompt': 'synthetic private decoy'}))
        self.assertFalse(self.exporter.observe_chat('not-a-uuid'))
        self.assertEqual(list(self.base.iterdir()), [])

    def test_record_is_private_identity_bound_and_metadata_only(self):
        self.assertTrue(self.exporter.observe_chat(A))
        data = json.loads(self.record.read_text())
        self.assertEqual(set(data), {'version', 'instanceId', 'sharing', 'pid', 'uid', 'startSeconds', 'startMicroseconds', 'chatIds', 'overflow', 'writtenAt'})
        self.assertEqual(data['pid'], os.getpid())
        self.assertEqual(data['uid'], os.getuid())
        self.assertEqual(data['sharing'], 'shared')
        self.assertEqual(data['chatIds'], [A])
        self.assertEqual(stat.S_IMODE(self.record.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.record.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.record.parent.parent.stat().st_mode), 0o700)

    def test_repeated_chat_has_no_heartbeat_write(self):
        self.assertTrue(self.exporter.observe_chat(A))
        before = self.record.stat()
        self.assertTrue(self.exporter.observe_chat(A))
        self.assertEqual(before.st_ino, self.record.stat().st_ino)
        self.assertEqual(before.st_mtime_ns, self.record.stat().st_mtime_ns)

    def test_chat_union_is_lifetime_bounded_without_forgetting_old_owner(self):
        self.assertTrue(self.exporter.observe_chat(A))
        self.assertTrue(self.exporter.observe_chat(B))
        for n in range(20):
            self.exporter.observe_chat(f'20000000-0000-0000-0000-{n:012d}')
        data = json.loads(self.record.read_text())
        self.assertEqual(len(data['chatIds']), 8)
        self.assertIn(A, data['chatIds'])
        self.assertIn(B, data['chatIds'])
        self.assertTrue(data['overflow'])
        self.assertLess(self.record.stat().st_size, ownership.MAX_BYTES)

    def test_symlink_root_never_follows_or_changes_target(self):
        target = self.base / 'synthetic-target'
        target.mkdir()
        (self.base / 'Stats Helper Ownership').symlink_to(target)
        self.assertFalse(self.exporter.observe_chat(A))
        self.assertEqual(list(target.iterdir()), [])

    def test_unsafe_directory_is_rejected_without_chmod(self):
        root = self.base / 'Stats Helper Ownership'
        root.mkdir(mode=0o755)
        self.assertFalse(self.exporter.observe_chat(A))
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o755)

    def test_final_symlink_is_replaced_atomically_without_following(self):
        self.assertTrue(self.exporter.observe_chat(A))
        target = self.base / 'synthetic-decoy'
        target.write_text('synthetic unchanged data')
        self.record.unlink()
        self.record.symlink_to(target)
        self.assertTrue(self.exporter.observe_chat(B))
        self.assertEqual(target.read_text(), 'synthetic unchanged data')
        self.assertFalse(self.record.is_symlink())

    def test_failed_update_retries_without_losing_new_chat(self):
        self.assertTrue(self.exporter.observe_chat(A))
        with mock.patch.object(ownership.os, 'replace', side_effect=OSError('synthetic failure')):
            self.assertFalse(self.exporter.observe_chat(B))
        self.assertTrue(self.exporter.observe_chat(B))
        self.assertEqual(json.loads(self.record.read_text())['chatIds'], [A, B])
        self.assertFalse(list(self.record.parent.glob('*.tmp')))

    def test_capacity_failure_leaves_existing_records_unchanged(self):
        fd = self.exporter._directory()
        folder = self.base / 'Stats Helper Ownership/v1'
        for n in range(128):
            (folder / f'synthetic-{n}').write_bytes(b'')
        self.assertFalse(self.exporter.observe_chat(A))
        self.assertFalse(self.record.exists())
        self.assertEqual(len(list(folder.iterdir())), 128)

    def test_normal_close_removes_only_own_instance(self):
        self.assertTrue(self.exporter.observe_chat(A))
        data = json.loads(self.record.read_text())
        data['instanceId'] = '20000000-0000-0000-0000-000000000001'
        self.record.write_text(json.dumps(data))
        self.exporter.close()
        self.assertTrue(self.record.exists())

    def test_closed_exporter_cannot_reappear(self):
        self.assertTrue(self.exporter.observe_chat(A))
        self.exporter.close()
        self.assertFalse(self.record.exists())
        self.assertFalse(self.exporter.observe_chat(B))


    def test_node_adapter_exports_untagged_parent_and_preserves_sharing(self):
        node = os.environ.get('STATS_TEST_NODE', 'node')
        environment = {k: v for k, v in os.environ.items() if k not in ('CODEX_THREAD_ID', 'CODEX_SESSION_ID')}
        demo = MODULE.with_name('demo.mjs')
        process = subprocess.Popen([node, '--max-old-space-size=64', str(demo), str(self.base), sys.executable],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=environment)
        def read():
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'Owned helper did not reply')
            return json.loads(process.stdout.readline())
        def observe(value):
            process.stdin.write(json.dumps({'chatId': value}) + '\n')
            process.stdin.flush()
            return read()
        try:
            self.assertEqual(read()['pid'], process.pid)
            self.assertFalse(observe('synthetic invalid value')['ok'])
            self.assertEqual(list(self.base.iterdir()), [])
            first = observe(A)
            self.assertTrue(first['ok'], first.get('status'))
            files = list((self.base / 'Stats Helper Ownership/v1').glob('*.json'))
            self.assertEqual(len(files), 1)
            record = json.loads(files[0].read_text())
            self.assertEqual(record['pid'], process.pid)
            self.assertNotEqual(record['pid'], os.getpid())
            before = files[0].stat().st_mtime_ns
            self.assertTrue(observe(A)['ok'])
            self.assertEqual(before, files[0].stat().st_mtime_ns)
            self.assertTrue(observe(B)['ok'])
            record = json.loads(files[0].read_text())
            self.assertEqual(record['chatIds'], [A, B])
            self.assertEqual(record['sharing'], 'shared')
            self.assertNotIn('title', record)
            process.stdin.write('{"close":true}\n'); process.stdin.flush()
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertFalse(files[0].exists())
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()


if __name__ == '__main__':
    unittest.main()

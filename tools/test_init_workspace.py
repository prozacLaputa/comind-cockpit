import json
import tempfile
import unittest
from pathlib import Path
from init_workspace import initialize


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cockpit-init-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.notes = self.root/'existing-notes'
        self.notes.mkdir()
        (self.notes/'Original.md').write_text('SYNTHETIC_ORIGINAL')
        self.workspace = self.root/'collaboration'

    def test_connect_existing_vault(self):
        initialize(self.workspace, self.notes)
        self.assertEqual((self.notes/'Original.md').read_text(), 'SYNTHETIC_ORIGINAL')
        self.assertTrue((self.workspace/'tools/scripts/knowledge-bridge/bridge.py').is_file())
        config = json.loads((self.workspace/'.local/knowledge-sources.json').read_text())
        self.assertEqual(config['notes_root'], str(self.notes))
        self.assertEqual(json.loads((self.notes/'.comind/registry.json').read_text())['documents'], [])
        before = (self.workspace/'.local/knowledge-sources.json').read_bytes()
        with self.assertRaises(ValueError): initialize(self.workspace, self.notes)
        self.assertEqual((self.workspace/'.local/knowledge-sources.json').read_bytes(), before)

    def test_preserves_existing_registry(self):
        (self.notes/'.comind').mkdir()
        file = self.notes/'.comind/registry.json'
        original = '{"version":1,"documents":[{"id":"original","path":"Original.md"}]}\n'
        file.write_text(original)
        initialize(self.workspace, self.notes)
        self.assertEqual(file.read_text(), original)

    def test_rejects_nested_or_symlink_sources(self):
        with self.assertRaises(ValueError): initialize(self.notes/'nested', self.notes)
        link = self.root/'linked-vault'; link.symlink_to(self.notes)
        with self.assertRaises(ValueError): initialize(self.workspace, link)
        self.assertFalse(self.workspace.exists())
        self.assertFalse((self.notes/'.comind').exists())


if __name__ == '__main__': unittest.main()

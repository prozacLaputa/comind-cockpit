import unittest,tempfile,json,sys,subprocess
from unittest.mock import patch
from pathlib import Path
from bridge import Bridge,Conflict,digest,atomic,json_bytes,safe
from transaction import Transaction

class Files(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); self.base=Path(self.tmp.name).resolve(); self.repo=self.base/'repo'; self.notes=self.base/'notes'; self.repo.mkdir(); self.notes.mkdir()
  atomic(self.repo/'.local/knowledge-sources.json',json_bytes({'notes_root':str(self.notes)}))
  atomic(self.notes/'主题/a.md',b'original')
  atomic(self.notes/'.comind/registry.json',json_bytes({'version':1,'documents':[{'id':'a','path':'主题/a.md','aliases':['corpus/old.md'],'sha256':digest(b'original'),'size':8}]}))
  self.b=Bridge(self.repo)
 def tearDown(self): self.tmp.cleanup()
 def test_alias_original_write_conflict_history(self):
  self.assertEqual(self.b.read('corpus/old.md')['text'],'original')
  result=self.b.update('note:a',digest(b'original'),'edited')
  self.assertEqual(Path(result['history']).read_bytes(),b'original')
  self.assertEqual(self.b.read('notes/主题/a.md')['text'],'edited')
  with self.assertRaises(Conflict): self.b.update('note:a',digest(b'original'),'stale')
  self.assertEqual(self.b.read('note:a')['text'],'edited')
 def test_rename_then_rebind(self):
  (self.notes/'主题/a.md').rename(self.notes/'主题/b.md')
  self.assertEqual(self.b.read('note:a')['text'],'original')
  (self.notes/'主题/b.md').write_text('new external text')
  with self.assertRaises(Conflict): self.b.read('note:a')
  self.b.rebind('a','主题/b.md')
  self.assertEqual(self.b.read('corpus/old.md')['text'],'new external text')
  self.assertEqual(self.b.read('notes/主题/a.md')['text'],'new external text')
 def test_rebind_version_guards_and_registry_history(self):
  before=self.b.registry_path.read_bytes()
  (self.notes/'主题/a.md').rename(self.notes/'主题/b.md')
  with self.assertRaises(Conflict): self.b.rebind('a','主题/b.md',expected_registry='stale')
  with self.assertRaises(Conflict): self.b.rebind('a','主题/b.md',expected_target='stale')
  with self.assertRaises(Conflict): self.b.rebind('a','主题/b.md',expected_old_path='wrong.md')
  self.assertEqual(self.b.registry_path.read_bytes(),before)
  result=self.b.rebind('a','主题/b.md',expected_registry=digest(before),expected_target=digest(b'original'),expected_old_path='主题/a.md')
  self.assertEqual(Path(result['history']).read_bytes(),before)
  self.assertEqual(self.b.read('notes/主题/a.md')['text'],'original')
  self.assertEqual(self.b.read('corpus/old.md')['text'],'original')
  with self.assertRaises(Conflict): self.b.rebind('a','主题/b.md',expected_registry=digest(before))
 def test_exact_patch_keeps_history_and_rejects_stale_retry(self):
  before=self.b.read('note:a')
  result=self.b.patch('note:a',before['sha256'],'original','current fact')
  self.assertTrue(result['changed'])
  self.assertEqual(Path(result['history']).read_text(),'original')
  self.assertEqual(self.b.read('note:a')['text'],'current fact')
  with self.assertRaises(Conflict):self.b.patch('note:a',before['sha256'],'original','duplicate')
  current=self.b.read('note:a')
  self.assertEqual(self.b.patch('note:a',current['sha256'],'current fact','current fact'),{'changed':False,'sha256':current['sha256']})
  self.assertEqual(len(list((self.notes/'主题/.history/a.md').glob('*.md'))),1)
  # Revert through the same protected write entry; a later manual edit must block it.
  (self.notes/'主题/a.md').write_text('manual edit')
  with self.assertRaises(Conflict):self.b.update('note:a',current['sha256'],Path(result['history']).read_text())
  self.b.update('note:a',self.b.read('note:a')['sha256'],Path(result['history']).read_text())
  self.assertEqual(self.b.read('note:a')['text'],'original')
 def test_patch_requires_unique_nonempty_anchor(self):
  for old,new in [('', 'append'),('missing','x'),('original',''),(None,'x')]:
   with self.assertRaises((Conflict,ValueError)):self.b.patch('note:a',digest(b'original'),old,new)
  (self.notes/'主题/a.md').write_text('repeat repeat')
  with self.assertRaises(Conflict):self.b.patch('note:a',digest(b'repeat repeat'),'repeat','once')
  self.assertEqual(self.b.read('note:a')['text'],'repeat repeat')
 def test_patch_cli_stdin_without_draft_file(self):
  result=subprocess.run([sys.executable,'-B',str(Path(__file__).with_name('bridge.py')),'--repo',str(self.repo),'patch','note:a','--expected-sha256',digest(b'original')],input=json.dumps({'old':'original','new':'CLI update'}),text=True,capture_output=True,check=True)
  receipt=json.loads(result.stdout)
  self.assertTrue(receipt['changed'])
  self.assertEqual(Path(receipt['history']).read_text(),'original')
  self.assertEqual(self.b.read('note:a')['text'],'CLI update')
 def test_native_stdin_and_cli_patch_share_history_registry_and_restore(self):
  args=[sys.executable,'-B',str(Path(__file__).with_name('bridge.py')),'--repo',str(self.repo),'write','note:a','--expected-sha256',digest(b'original'),'--expected-path',str(self.notes/'主题/a.md'),'--stdin']
  result=subprocess.run(args,input='native edit\n中文',text=True,capture_output=True,check=True)
  receipt=json.loads(result.stdout)
  self.assertEqual(Path(receipt['history']).read_text(),'original')
  self.assertEqual(self.b.registry()['documents'][0]['sha256'],receipt['sha256'])
  changed=self.b.patch('note:a',receipt['sha256'],'native edit','CLI correction')
  self.assertEqual(Path(changed['history']).read_text(),'native edit\n中文')
  restored=self.b.update('note:a',changed['sha256'],Path(receipt['history']).read_text())
  self.assertEqual(self.b.read('note:a')['text'],'original')
  self.assertEqual(Path(restored['history']).read_text(),'CLI correction\n中文')
  self.assertEqual(len(list((self.notes/'主题/.history/a.md').glob('*.md'))),3)
 def test_full_write_noop_has_no_extra_history(self):
  self.assertEqual(self.b.update('note:a',digest(b'original'),'original'),{'changed':False,'sha256':digest(b'original')})
  self.assertFalse((self.notes/'主题/.history').exists())
  with self.assertRaises(Conflict):self.b.update('note:a',digest(b'old'),'original')
 def test_incomplete_stdin_never_replaces_the_original(self):
  args=[sys.executable,'-B',str(Path(__file__).with_name('bridge.py')),'--repo',str(self.repo),'write','note:a','--expected-sha256',digest(b'original'),'--content-sha256',digest(b'complete edit'),'--stdin']
  result=subprocess.run(args,input='complete',text=True,capture_output=True)
  self.assertNotEqual(result.returncode,0)
  self.assertEqual(self.b.read('note:a')['text'],'original')
  self.assertFalse((self.notes/'主题/.history').exists())
 def test_expected_path_rejects_rebinding_even_when_content_equal(self):
  atomic(self.notes/'主题/b.md',b'original')
  self.b.rebind('a','主题/b.md')
  with self.assertRaises(Conflict):self.b.update('note:a',digest(b'original'),'wrong file',str(self.notes/'主题/a.md'))
  self.assertEqual((self.notes/'主题/b.md').read_text(),'original')
 def test_write_readback_failure_is_not_success(self):
  target=self.notes/'主题/a.md'
  def external_edit(path,data):
   atomic(path,data)
   if Path(path)==target: target.write_text('external change after write')
  with patch('bridge.atomic',side_effect=external_edit):
   with self.assertRaises(Conflict):self.b.patch('note:a',digest(b'original'),'original','requested change')
  self.assertEqual(target.read_text(),'external change after write')
  self.assertEqual(next((self.notes/'主题/.history/a.md').glob('*.md')).read_text(),'original')
 def test_create_is_single_original_no_overwrite(self):
  result=self.b.create('主题/new.md','created once')
  self.assertEqual(self.b.read(result['reference'])['text'],'created once')
  with self.assertRaises(Conflict):self.b.create('主题/new.md','overwrite')
  with self.assertRaises(ValueError):self.b.create('../outside.md','escape')
 def test_no_traversal_symlink_hidden(self):
  for path in ['../x','主题/../../x','/tmp/x','.obsidian/app.json']:
   with self.assertRaises(ValueError): self.b.resolve('notes/'+path)
  (self.notes/'主题/link.md').symlink_to(self.base/'outside')
  with self.assertRaises(ValueError): self.b.read('notes/主题/link.md')
 def test_ambiguous_rename_no_guess(self):
  (self.notes/'主题/a.md').unlink()
  (self.notes/'b.md').write_bytes(b'original');(self.notes/'c.md').write_bytes(b'original')
  with self.assertRaises(Conflict): self.b.read('note:a')
 def txn(self): return Transaction(self.base/'txn',[self.repo,self.notes])
 def test_rollback_and_newer_user_files(self):
  t=self.txn();a=self.notes/'主题/a.md'; dest=self.notes/'moved.md'
  t.add(dest,a.read_bytes()); t.add(a,None); t.apply()
  (self.notes/'user-new.md').write_text('keep me')
  self.assertEqual(t.rollback()['status'],'ready');t.rollback(True);t.rollback(True)
  self.assertEqual(a.read_bytes(),b'original'); self.assertFalse(dest.exists());self.assertEqual((self.notes/'user-new.md').read_text(),'keep me')
 def test_rollback_refuses_newer_edits_atomically(self):
  t=self.txn();a=self.notes/'主题/a.md';b=self.notes/'b.md';t.add(a,b'changed');t.add(b,b'created');t.apply();a.write_bytes(b'newer')
  self.assertEqual(t.rollback(True)['status'],'blocked-newer-edits'); self.assertEqual(b.read_bytes(),b'created');self.assertEqual(a.read_bytes(),b'newer')
 def test_preflight_and_partial_recovery(self):
  t=self.txn();a=self.notes/'主题/a.md';b=self.notes/'b.md';t.add(a,b'changed');t.add(b,b'created');b.write_bytes(b'user-created')
  with self.assertRaises(Conflict):t.apply()
  self.assertEqual(a.read_bytes(),b'original');b.unlink()
  a.write_bytes(b'changed') # Simulate interruption after first atomic write, before journal update.
  t=Transaction(self.base/'txn');self.assertEqual(t.rollback(True)['status'],'rolled-back');self.assertEqual(a.read_bytes(),b'original')
 def test_corrupt_backup_refused(self):
  t=self.txn();a=self.notes/'主题/a.md';t.add(a,b'new');t.apply();(t.directory/'0000-before.bin').write_bytes(b'corrupt')
  with self.assertRaises(Conflict):t.rollback(True)
  self.assertEqual(a.read_bytes(),b'new')
 def test_transaction_path_escape(self):
  t=self.txn()
  with self.assertRaises(ValueError):t.add(self.repo/'../outside',b'x')

if __name__=='__main__':unittest.main()

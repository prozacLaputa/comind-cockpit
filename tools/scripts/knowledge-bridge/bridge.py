#!/usr/bin/env python3
"""CoMind 与 Obsidian 的同源文件入口。索引只保存地址；不读取未请求的正文。"""
from __future__ import annotations
import argparse, hashlib, json, os, re, sys, tempfile, uuid
from datetime import datetime, timezone
from pathlib import Path
from contextlib import contextmanager
import fcntl

class Conflict(RuntimeError): pass

def digest(data): return hashlib.sha256(data).hexdigest()
def json_bytes(value): return (json.dumps(value, ensure_ascii=False, indent=2)+'\n').encode()
def load(path): return json.loads(Path(path).read_text())
def atomic(path, data):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    fd, temp=tempfile.mkstemp(prefix='.comind-write-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as out: out.write(data); out.flush(); os.fsync(out.fileno())
        if path.exists(): os.chmod(temp,path.stat().st_mode & 0o777)
        os.replace(temp,path)
    finally:
        if os.path.exists(temp): os.unlink(temp)

def safe(root, relative, hidden=False):
    root=Path(root).absolute()
    p=Path(relative)
    if p.is_absolute() or not p.parts or any(x in ('..','.') or (x.startswith('.') and not hidden) for x in p.parts):
        raise ValueError('无效相对路径')
    cursor=root
    if root.is_symlink(): raise ValueError('来源根不能是符号链接')
    for part in p.parts:
        cursor=cursor/part
        if cursor.is_symlink(): raise ValueError('禁止跨符号链接访问')
    if not cursor.resolve().is_relative_to(root.resolve()): raise ValueError('来源越界')
    return cursor

@contextmanager
def locked(path):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    if path.is_symlink(): raise ValueError('锁路径不能是符号链接')
    with path.open('a') as f:
        fcntl.flock(f,fcntl.LOCK_EX)
        yield
        fcntl.flock(f,fcntl.LOCK_UN)

class Bridge:
    def __init__(self, repo):
        self.repo=Path(repo).resolve()
        config=safe(self.repo,'.local/knowledge-sources.json',hidden=True)
        self.config=load(config)
        self.notes=Path(self.config['notes_root']).absolute()
        if not self.notes.is_dir() or self.notes.is_symlink(): raise FileNotFoundError('笔记来源不可用，请重新绑定或等待下载')
        self.registry_path=safe(self.notes,'.comind/registry.json',hidden=True)
    def registry(self):
        value=load(self.registry_path)
        if value.get('version')!=1: raise ValueError('不支持的来源登记版本')
        return value
    def resolve(self, reference):
        registry=self.registry()
        entries=registry['documents']
        matches=[x for x in entries if reference==f"note:{x['id']}" or reference==f"notes/{x['path']}" or reference in x.get('aliases',[])]
        if len(matches)>1: raise Conflict('来源身份冲突，需重新定位')
        if not matches:
            if reference.startswith('notes/'):
                return safe(self.notes,reference[6:]), None
            if reference.startswith('note:'): raise FileNotFoundError('未登记的文档标识')
            for old,new in self.config.get('routes',{}).items():
                if reference.startswith(old): return safe(self.notes,new+reference[len(old):]),None
            return safe(self.repo,reference), None
        entry=matches[0]
        path=safe(self.notes,entry['path'])
        if path.is_file(): return path,entry
        # Rename recovery hashes only size-matching files, never exports their contents.
        candidates=[]
        for parent, dirs, files in os.walk(self.notes):
            dirs[:]=[x for x in dirs if not x.startswith('.') and not (Path(parent)/x).is_symlink()]
            for name in files:
                q=Path(parent)/name
                if q.is_symlink() or name.startswith('.') or q.suffix!=path.suffix: continue
                if q.stat().st_size==entry.get('size') and digest(q.read_bytes())==entry.get('sha256'): candidates.append(q)
        if len(candidates)!=1: raise Conflict('来源已移动、被修改或暂不可用；请显式重新定位，不会新建替代文件')
        return candidates[0],entry
    def read(self, reference):
        path,entry=self.resolve(reference)
        if not path.is_file(): raise FileNotFoundError('来源文件不可用')
        if path.stat().st_size>1_000_000: raise ValueError('原文超过 1 MB')
        data=path.read_bytes()
        if len(data)>1_000_000: raise ValueError('原文超过 1 MB')
        text=data.decode('utf-8')
        return {'reference':reference,'path':str(path),'sha256':digest(data),'text':text}
    def update(self, reference, expected, text, expected_path=None):
        if len(text.encode())>1_000_000: raise ValueError('修改超过 1 MB')
        with locked(safe(self.notes,'.comind/write.lock',hidden=True)):
            path,entry=self.resolve(reference)
            if expected_path is not None and path.absolute()!=Path(expected_path).absolute():
                raise Conflict('原件位置已变化，请重新读取后再保存')
            current=self.read(reference)
            if current['sha256']!=expected: raise Conflict('原件已变化，保留双方内容并重新核对')
            if current['text']==text: return {'changed':False,'sha256':expected}
            history=safe(path.parent,'.history/'+path.name,hidden=True)
            history.mkdir(parents=True,exist_ok=True)
            backup=history/(uuid.uuid4().hex+'.md')
            atomic(backup,current['text'].encode())
            # Check again after recording history; cooperating writers share this lock.
            if digest(path.read_bytes())!=expected: raise Conflict('保存前原件再次变化，未覆盖')
            atomic(path,text.encode())
            if path.read_bytes()!=text.encode():
                raise Conflict('写后回读不一致，请核对原件与历史，不能报告保存成功')
            if entry:
                registry=self.registry()
                for x in registry['documents']:
                    if x['id']==entry['id']:
                        previous='notes/'+x['path']; rel=str(path.relative_to(self.notes))
                        if previous!='notes/'+rel: x['aliases']=list(dict.fromkeys(x.get('aliases',[])+[previous]))
                        x.update(path=rel,sha256=digest(text.encode()),size=len(text.encode()))
                atomic(self.registry_path,json_bytes(registry))
            if path.read_bytes()!=text.encode():
                raise Conflict('写后回读不一致，请核对原件与历史，不能报告保存成功')
            return {'changed':True,'sha256':digest(text.encode()),'history':str(backup)}
    def patch(self, reference, expected, old, new):
        """One exact, versioned edit; no temporary second copy of a private note."""
        if not isinstance(old,str) or not isinstance(new,str) or not old:
            raise ValueError('old 必须为非空原文，new 必须为文本')
        current=self.read(reference)
        if current['sha256']!=expected: raise Conflict('原件已变化，保留双方内容并重新核对')
        if current['text'].count(old)!=1: raise Conflict('原文片段须唯一匹配；不会猜测或全局替换')
        if old==new: return {'changed':False,'sha256':expected}
        after=current['text'].replace(old,new,1)
        if not after.strip(): raise ValueError('不能通过片段更新清空原笔记')
        result=self.update(reference,expected,after)
        return {'changed':True,**result}
    def organization_path(self, identity):
        # Receipts live beside existing consolidation metadata, never contain note bodies.
        if not isinstance(identity,str) or not re.fullmatch(r'[0-9a-fA-F-]{36}',identity):
            raise ValueError('无效整理标识')
        uuid.UUID(identity)
        return safe(self.notes,'.comind/consolidation/cockpit-runs/'+identity+'.json',hidden=True)
    def routing(self, area, references):
        """One rule source for manual and daily organization; no personal prose."""
        path=safe(self.repo,'tools/scripts/knowledge-bridge/writeback-routing.json')
        data=path.read_bytes() if path.exists() else b''
        config=json.loads(data) if data else {'version':1,'areas':{}}
        if config.get('version')!=1 or not isinstance(config.get('areas'),dict): raise ValueError('内容归属规则格式不支持')
        rules=config['areas'].get(area)
        managed={t['reference'] for a in config['areas'].values() for t in a['targets']}
        # A caller cannot omit its area to bypass already configured targets.
        if not rules and managed:
            files={str(self.resolve(r)[0]) for r in references}
            if any(str(self.resolve(r)[0]) in files for r in managed): raise Conflict('整理这些原件必须提供阵地身份与内容归属规则')
        selected=[]
        if rules:
            for ref in references:
                file=self.resolve(ref)[0]
                matches=[t for t in rules['targets'] if self.resolve(t['reference'])[0]==file]
                if len(matches)!=1: raise Conflict('此原件尚未配置本阵地的内容归属，请先核对规则')
                rule=matches[0]
                if not isinstance(rule.get('categories'),dict) or not rule['categories'] or not all(isinstance(k,str) and isinstance(v,str) for k,v in rule['categories'].items()): raise ValueError('内容类别规则无效')
                selected.append(dict(rule,reference=ref))
        common='同一事实只写最合适的一篇；先跨选中原件去重。只整理持续有用的本人信息；AI 推断、歧义或冲突留同页待核对。超出内容范围的文字跳过，不得借待核对写入无关主题。原话、日期、说话者及来源必须保留；未知不猜测。'
        text=common
        for rule in selected:
            text+='\n原件：'+rule['reference']+'\n允许类别：'+json.dumps(rule['categories'],ensure_ascii=False)+'\n不写入：'+rule['exclude']
        if selected:
            text+='\n自动 apply 每条 entries 必须提供 category；手动 organization-patch 的 stdin 必须提供 categories 清单。类别必须匹配目标。程序核对类别和版本，内容是否属于该类别仍须逐条核读证据，不靠贴标签通过。'
        return {'snapshot':{'area':area,'sha256':digest(data)},'targets':selected,'text':text}
    def organization_routing(self, run):
        current=self.routing(run.get('area'),[t['reference'] for t in run['targets']])
        previous=run.get('routing')
        if previous is not None and previous!=current['snapshot']: raise Conflict('内容归属规则已变化，停止旧整理计划')
        if previous is None and current['targets']: raise Conflict('旧整理批次缺少内容归属规则，请重新核对')
        return current
    def organization_categories(self, run, reference, categories):
        rules=self.organization_routing(run)
        target=next((t for t in rules['targets'] if t['reference']==reference),None)
        if target and (not isinstance(categories,list) or not categories or any(not isinstance(c,str) or c not in target['categories'] for c in categories)):
            raise Conflict('内容类别不属于该原件，请跳过或按已批准的归属重新整理')
    def organization_start(self, identity, plan, automatic=None):
        path=self.organization_path(identity)
        with locked(path.with_suffix('.lock')):
            if path.exists(): raise Conflict('整理标识已存在，不重复开始')
            if set(plan)-{'area'}!={'thread','turn_ids','limited','targets'} or not isinstance(plan['thread'],str) or not plan['thread'] or len(plan['thread'])>200:
                raise ValueError('无效整理范围')
            area=plan.get('area') or (automatic or {}).get('area')
            if area is not None and (not isinstance(area,str) or not area or len(area)>200): raise ValueError('无效阵地身份')
            if not isinstance(plan['limited'],bool) or not isinstance(plan['turn_ids'],list) or not 0<len(plan['turn_ids'])<=20 or any(not isinstance(t,str) or not t or len(t)>200 for t in plan['turn_ids']) or len(set(plan['turn_ids']))!=len(plan['turn_ids']):
                raise ValueError('无效来源轮次')
            if not isinstance(plan['targets'],list) or not 0<len(plan['targets'])<=30: raise ValueError('请选择已有原笔记')
            targets=[]; seen=set()
            for target in plan['targets']:
                if set(target)!={'reference','sha256'}: raise ValueError('无效目标')
                current=self.read(target['reference']); file=Path(current['path'])
                if not file.is_relative_to(self.notes) or file.suffix!='.md' or any(p.startswith('.') or '日记' in p or '梦境' in p for p in file.relative_to(self.notes).parts) or re.fullmatch(r'\d{4}[-.]\d{1,2}[-.]\d{1,2}',file.stem):
                    raise ValueError('整理仅允许已有主题原笔记，不处理日记、插件或协作规则')
                if current['sha256']!=target['sha256']: raise Conflict('原件已变化，尚未开始整理')
                if str(file) in seen: raise Conflict('同一原件重复选择')
                seen.add(str(file))
                targets.append({'reference':target['reference'],'path':str(file),'before_sha256':current['sha256'],'sha256':current['sha256'],'state':'pending','history':[]})
            run={'version':1,'id':identity,'thread':plan['thread'],'turn_ids':plan['turn_ids'],'limited':plan['limited'],
                 'started_at':datetime.now(timezone.utc).isoformat(),'state':'open','targets':targets}
            routing=self.routing(area,[t['reference'] for t in targets])
            run.update(area=area,routing=routing['snapshot'])
            if automatic is not None: run['automatic']=automatic
            atomic(path,json_bytes(run)); return run
    def organization_list(self):
        root=safe(self.notes,'.comind/consolidation/cockpit-runs',hidden=True)
        results=[]
        for path in root.glob('*.json'):
            run=self.organization_load(path.stem); auto=run.get('automatic')
            if not auto: continue
            results.append({'id':run['id'],'area':auto['area'],'thread':run['thread'],
                            'repository':self.repo.as_uri(),'sources':auto['sources'],
                            'started':datetime.fromisoformat(run['started_at']).timestamp()-978307200,
                            'state':'finished' if run['state']=='completed' else 'interrupted',
                            'automatic':True})
        return sorted(results,key=lambda x:x['started'])[-100:]
    def organization_load(self, identity):
        value=load(self.organization_path(identity))
        if value.get('version')!=1 or value.get('id')!=identity: raise Conflict('整理回执身份不符')
        return value
    def organization_patch(self, identity, reference, expected, old, new, categories=None):
        path=self.organization_path(identity)
        with locked(path.with_suffix('.lock')):
            run=self.organization_load(identity)
            target=next((t for t in run['targets'] if t['reference']==reference),None)
            if run['state']!='open' or not target or target['state'] not in ('pending','written'):
                raise Conflict('本次整理未授权此目标，或上次写入尚未核实')
            self.organization_categories(run,reference,categories)
            current=self.read(reference)
            if current['path']!=target['path'] or current['sha256']!=expected or expected!=target['sha256']:
                raise Conflict('原件或版本变化，停止旧整理计划')
            target['state']='writing'; atomic(path,json_bytes(run))
            # Persist intent first. On a crash/failure, status stays unverified; never replay the patch.
            result=self.patch(reference,expected,old,new)
            if result['changed']:
                target['history'].append({'path':result['history'],'before_sha256':expected,'sha256':result['sha256']})
            target['sha256']=result['sha256']; target['state']='written' if target['history'] else 'pending'
            atomic(path,json_bytes(run))
            return {'operation_id':identity,'reference':reference,**result}
    def organization_complete(self, identity, unchanged):
        path=self.organization_path(identity)
        with locked(path.with_suffix('.lock')):
            run=self.organization_load(identity)
            if run['state']!='open': raise Conflict('整理已经结束，不重复完成')
            self.organization_routing(run)
            if not isinstance(unchanged,list) or any(not isinstance(x,str) for x in unchanged) or len(unchanged)!=len(set(unchanged)): raise ValueError('无效无新增清单')
            pending=[t['reference'] for t in run['targets'] if t['state']=='pending']
            if set(unchanged)!=set(pending): raise Conflict('每份未改笔记都须明确核对为无新增')
            checked={t['reference']:t for t in self.organization_status(identity)['targets']}
            for t in run['targets']:
                if t['state']=='written' and not checked[t['reference']]['verified']: raise Conflict('写入历史无法核实，不能完成整理')
                current=self.read(t['reference'])
                if t['state'] not in ('pending','written') or current['path']!=t['path'] or current['sha256']!=t['sha256']:
                    raise Conflict('部分写入未核实或原件已变化，不能宣称整理完成')
                if t['state']=='pending': t['state']='unchanged'
            run['state']='completed'; run['finished_at']=datetime.now(timezone.utc).isoformat()
            atomic(path,json_bytes(run)); return run
    def organization_status(self, identity):
        run=self.organization_load(identity)
        for t in run['targets']:
            try:
                current=self.read(t['reference'])
                t['current_sha256']=current['sha256']
                t['current_matches']=current['path']==t['path'] and current['sha256']==t['sha256']
                # History provenance remains verifiable even after a later manual edit.
                chain=t['before_sha256']
                for h in t['history']:
                    file=Path(t['path']); expected=safe(file.parent,'.history/'+file.name+'/'+Path(h['path']).name,hidden=True)
                    if str(expected)!=h['path'] or h['before_sha256']!=chain or digest(expected.read_bytes())!=chain: raise Conflict('历史回执不完整')
                    chain=h['sha256']
                t['verified']=chain==t['sha256'] and t['state'] in ('written','unchanged')
            except (OSError,ValueError,Conflict):
                t['verified']=False; t['current_matches']=False
        return run
    def rebind(self, identity, relative, expected_registry=None, expected_target=None, expected_old_path=None):
        path=safe(self.notes,relative)
        if not path.is_file(): raise FileNotFoundError('重新定位目标不存在')
        with locked(safe(self.notes,'.comind/write.lock',hidden=True)):
            before=self.registry_path.read_bytes()
            if expected_registry and digest(before)!=expected_registry: raise Conflict('来源登记已变化，请重新选择并核对')
            registry=self.registry(); entry=next((x for x in registry['documents'] if x['id']==identity),None)
            if not entry: raise ValueError('未知文档标识')
            if expected_old_path is not None and entry['path']!=expected_old_path: raise Conflict('原件位置已变化')
            content=path.read_bytes()
            if expected_target and digest(content)!=expected_target: raise Conflict('所选文件已变化，请重新核对')
            if any(x['id']!=identity and x['path']==relative for x in registry['documents']): raise Conflict('目标已有另一个文档身份')
            entry['aliases']=list(dict.fromkeys(entry.get('aliases',[])+['notes/'+entry['path']]))
            entry.update(path=relative,sha256=digest(content),size=len(content))
            history=safe(self.notes,'.comind/history/registry-'+str(uuid.uuid4())+'.json',hidden=True)
            history.parent.mkdir(parents=True,exist_ok=True)
            with history.open('xb') as f: f.write(before); f.flush(); os.fsync(f.fileno())
            atomic(self.registry_path,json_bytes(registry))
            if self.registry()!=registry: raise Conflict('重新定位回读不一致，请检查登记历史')
            return {'id':identity,'path':relative,'history':str(history)}
    def create(self, relative, text):
        data=text.encode('utf-8')
        if len(data)>1_000_000 or not relative.endswith('.md'): raise ValueError('只创建小于 1 MB 的 Markdown')
        path=safe(self.notes,relative)
        with locked(safe(self.notes,'.comind/write.lock',hidden=True)):
            registry=self.registry()
            if path.exists() or any(x['path']==relative for x in registry['documents']): raise Conflict('目标已有内容或身份，请使用写前版本核对')
            path.parent.mkdir(parents=True,exist_ok=True)
            with path.open('xb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
            identity=str(uuid.uuid4())
            registry['documents'].append({'id':identity,'path':relative,'aliases':[],'size':len(data),'sha256':digest(data)})
            try: atomic(self.registry_path,json_bytes(registry))
            except Exception:
                # Do not remove a file somebody else edited while registry publication failed.
                if path.is_file() and digest(path.read_bytes())==digest(data): path.unlink()
                raise
            return {'reference':'note:'+identity,'path':str(path),'sha256':digest(data)}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo',default=str(Path(__file__).resolve().parents[3]))
    sub=p.add_subparsers(dest='command',required=True)
    for command in ['resolve','read']:
        s=sub.add_parser(command); s.add_argument('reference')
    s=sub.add_parser('write'); s.add_argument('reference'); s.add_argument('--expected-sha256',required=True); s.add_argument('--expected-path'); s.add_argument('--content-sha256')
    content=s.add_mutually_exclusive_group(required=True)
    content.add_argument('--text-file'); content.add_argument('--stdin',action='store_true',help='从标准输入读取 UTF-8 正文，不创建临时稿件')
    s=sub.add_parser('patch',help='从标准输入读取 JSON {old,new}，只替换唯一原文片段，保留同域历史')
    s.add_argument('reference'); s.add_argument('--expected-sha256',required=True)
    sub.add_parser('organization-list')
    for name in ['organization-start','organization-status','organization-complete','organization-instructions']:
        s=sub.add_parser(name); s.add_argument('id')
    s=sub.add_parser('organization-patch'); s.add_argument('id'); s.add_argument('reference'); s.add_argument('--expected-sha256',required=True)
    s=sub.add_parser('rebind'); s.add_argument('id'); s.add_argument('relative_path'); s.add_argument('--expected-registry-sha256'); s.add_argument('--expected-target-sha256'); s.add_argument('--expected-old-path')
    s=sub.add_parser('create'); s.add_argument('relative_path'); s.add_argument('--text-file',required=True)
    sub.add_parser('root')
    a=p.parse_args(); b=Bridge(a.repo)
    if a.command=='resolve': result={'path':str(b.resolve(a.reference)[0])}
    elif a.command=='read': result=b.read(a.reference)
    elif a.command=='write':
        if a.stdin:
            raw=sys.stdin.buffer.read(1_000_001)
            if len(raw)>1_000_000: raise ValueError('修改超过 1 MB')
            text=raw.decode('utf-8')
        else: text=Path(a.text_file).read_text()
        if a.content_sha256 is not None and digest(text.encode('utf-8'))!=a.content_sha256:
            raise Conflict('修改正文未完整收到，未写入原件')
        result=b.update(a.reference,a.expected_sha256,text,a.expected_path)
    elif a.command=='patch':
        raw=sys.stdin.buffer.read(2_000_001)
        if len(raw)>2_000_000: raise ValueError('修改输入过大')
        patch=json.loads(raw)
        if not isinstance(patch,dict) or set(patch)!={'old','new'}: raise ValueError('只接受 old 与 new 两个字段')
        result=b.patch(a.reference,a.expected_sha256,patch['old'],patch['new'])
    elif a.command=='organization-list': result=b.organization_list()
    elif a.command=='organization-status': result=b.organization_status(a.id)
    elif a.command=='organization-instructions': result=b.organization_routing(b.organization_load(a.id))
    elif a.command.startswith('organization-'):
        raw=sys.stdin.buffer.read(2_000_001)
        if len(raw)>2_000_000: raise ValueError('整理输入过大')
        payload=json.loads(raw)
        if a.command=='organization-start': result=b.organization_start(a.id,payload)
        elif a.command=='organization-complete':
            if not isinstance(payload,dict) or set(payload)!={'unchanged'}: raise ValueError('只接受 unchanged 清单')
            result=b.organization_complete(a.id,payload['unchanged'])
        else:
            if not isinstance(payload,dict) or set(payload)-{'categories'}!={'old','new'}: raise ValueError('只接受 old、new 与可选 categories 字段')
            result=b.organization_patch(a.id,a.reference,a.expected_sha256,payload['old'],payload['new'],payload.get('categories'))
    elif a.command=='rebind': result=b.rebind(a.id,a.relative_path,a.expected_registry_sha256,a.expected_target_sha256,a.expected_old_path)
    elif a.command=='create': result=b.create(a.relative_path,Path(a.text_file).read_text())
    else: result={'notes_root':str(b.notes),'routes':b.config.get('routes',{})}
    print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__': main()

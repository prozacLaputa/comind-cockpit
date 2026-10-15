"""带预检和版本保护的本地文件事务；回退不覆盖执行后的用户编辑。"""
from pathlib import Path
import hashlib,json,os,stat,uuid
from bridge import atomic,digest,json_bytes,load,Conflict

class Transaction:
    def __init__(self, directory, roots=None):
        self.directory=Path(directory).resolve()
        self.directory.mkdir(parents=True,exist_ok=True,mode=0o700); os.chmod(self.directory,0o700)
        self.manifest=self.directory/'transaction.json'
        if self.manifest.exists(): self.data=load(self.manifest)
        else:
            self.data={'version':1,'id':self.directory.name,'roots':[str(Path(x).resolve()) for x in roots or []],'operations':[],'status':'prepared'}
            self.save()
    def save(self): atomic(self.manifest,json_bytes(self.data))
    def checked_path(self,path):
        p=Path(path).absolute()
        if '..' in p.parts: raise ValueError('事务路径禁止目录遍历')
        if not any(p.is_relative_to(Path(r)) for r in self.data['roots']): raise ValueError('事务路径不在批准范围')
        cursor=p
        while cursor!=cursor.parent:
            if cursor.is_symlink(): raise ValueError('事务拒绝符号链接')
            cursor=cursor.parent
        if p.exists() and not p.is_file(): raise ValueError('事务仅处理普通文件')
        return p
    def add(self,path,after):
        if self.data['status']!='prepared': raise Conflict('已开始的事务不可追加操作')
        p=self.checked_path(path)
        if any(x['path']==str(p) for x in self.data['operations']): raise Conflict('重复事务路径')
        before=p.read_bytes() if p.is_file() else None
        i=len(self.data['operations']); entry={'path':str(p),'before':digest(before) if before is not None else None,'after':digest(after) if after is not None else None,'mode':stat.S_IMODE(p.stat().st_mode) if p.exists() else 0o600,'status':'pending'}
        for key,value in [('before',before),('after',after)]:
            if value is not None:
                blob=f'{i:04d}-{key}.bin'; atomic(self.directory/blob,value); entry[key+'_blob']=blob
        self.data['operations'].append(entry); self.save()
    def current(self,p): return digest(p.read_bytes()) if p.is_file() else None
    def verify_blobs(self):
        for e in self.data['operations']:
            self.checked_path(e['path'])
            for key in ['before','after']:
                if e[key] is not None:
                    name=e[key+'_blob']
                    if Path(name).name!=name or (self.directory/name).is_symlink(): raise Conflict('非法快照路径')
                    if digest((self.directory/name).read_bytes())!=e[key]: raise Conflict('备份/目标快照校验失败')
    def apply(self):
        self.verify_blobs()
        if self.data['status']!='prepared': raise Conflict('请先核对已有事务状态')
        if any(self.current(Path(e['path']))!=e['before'] for e in self.data['operations']): raise Conflict('预检发现源或目标改变，整个事务未执行')
        self.data['status']='applying'; self.save()
        for e in self.data['operations']:
            p=self.checked_path(e['path'])
            if self.current(p)!=e['before']: raise Conflict('执行中发现外部编辑，已停止；可安全回退已完成项')
            if e['after'] is None:
                if p.exists(): p.unlink()
            else:
                atomic(p,(self.directory/e['after_blob']).read_bytes()); os.chmod(p,e['mode'])
            if self.current(p)!=e['after']: raise Conflict('写后校验失败，需检查事务记录')
            e['status']='applied'; self.save()
        self.data['status']='applied'; self.save()
    def rollback(self,execute=False):
        self.verify_blobs()
        if self.data['status']=='rolled-back': return {'status':'rolled-back','conflicts':0,'operations':0}
        conflicts=[e for e in self.data['operations'] if self.current(self.checked_path(e['path'])) not in (e['before'],e['after'])]
        if conflicts: return {'status':'blocked-newer-edits','conflicts':len(conflicts),'operations':len(self.data['operations'])}
        if not execute: return {'status':'ready','conflicts':0,'operations':len(self.data['operations'])}
        for e in reversed(self.data['operations']):
            p=self.checked_path(e['path']); current=self.current(p)
            if current==e['before']: continue
            if current!=e['after']: raise Conflict('回退中检测到新编辑，停止覆盖')
            if e['before'] is None:
                if p.exists(): p.unlink()
            else:
                atomic(p,(self.directory/e['before_blob']).read_bytes()); os.chmod(p,e['mode'])
            e['status']='rolled-back'; self.save()
        self.data['status']='rolled-back'; self.save()
        return {'status':'rolled-back','conflicts':0,'operations':len(self.data['operations'])}

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(); p.add_argument('directory'); p.add_argument('--execute',action='store_true'); a=p.parse_args()
    print(json.dumps(Transaction(a.directory).rollback(a.execute),ensure_ascii=False))

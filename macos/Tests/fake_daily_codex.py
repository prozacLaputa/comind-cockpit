#!/usr/bin/python3
"""Synthetic daily-use service. No network, model or original-note access."""
import json, sys, tempfile
from pathlib import Path
root = tempfile.TemporaryDirectory(prefix='cockpit-daily-service-')
turns = {'daily-a': [], 'daily-b': []}
versions = {'daily-a': 1, 'daily-b': 1}
logs = []
fail_read = False
active = None

def metadata(key):
    return dict(id=key, name='合成会话 '+key, cwd=root.name, path=__file__, updatedAt=versions[key], historyMode='paginated', status={'type':'active' if active and active[0]==key else 'idle'})
def event(method, params):
    print(json.dumps({'method':method,'params':params}), flush=True)
def external(key):
    versions[key] += 1
    turns[key].append({'id':'external-'+str(versions[key]), 'status':'completed','items':[{'id':'q','type':'userMessage','content':[{'type':'text','text':'外部新增 '+str(versions[key])}]},{'id':'a','type':'agentMessage','text':'新回复 '+str(versions[key])}]})
external('daily-a')
for line in sys.stdin:
    r=json.loads(line)
    if 'id' not in r or 'method' not in r: continue
    m=r['method']; p=r.get('params',{}); result={}; error=None
    if m=='config/read' and 'fixtureControl' in p: m='test/'+p['fixtureControl']
    if m=='account/read': result={'account':{'type':'chatgpt','planType':'fixture'}}
    elif m=='thread/list': result={'data':[metadata(k) for k in turns], 'nextCursor':None}
    elif m=='thread/read': result={'thread':metadata(p['threadId'])}
    elif m=='thread/turns/list':
        if fail_read: error={'code':-1,'message':'synthetic page unavailable'}
        else: result={'data':list(reversed(turns[p['threadId']])), 'nextCursor':None}
    elif m=='thread/resume': result={'thread':metadata(p['threadId'])}
    elif m=='thread/start':
        key='daily-new-'+str(len(turns));turns[key]=[];versions[key]=1
        result={'thread':metadata(key)}
    elif m=='turn/start':
        assert p['sandboxPolicy']['type']=='readOnly' and p['approvalPolicy']=='on-request'
        assert active is None, 'Concurrent execution is forbidden'
        logs.append(p)
        if 'REJECT' in p['input'][0]['text']: error={'code':-2,'message':'synthetic rejection'}
        else:
            for image in [x for x in p['input'] if x['type']=='localImage']:
                assert Path(image['path']).is_file() and 'Chat Attachments' in image['path']
            key=p['threadId']; turn={'id':'sent-'+str(len(logs)),'status':'inProgress','items':[{'id':'user-'+str(len(logs)),'type':'userMessage','content':p['input']}]}
            turns[key].append(turn);versions[key]+=1;active=(key,turn)
            result={'turn':turn}
    elif m in ('test/complete','turn/interrupt'):
        if active:
            key,turn=active; turn['status']=p.get('status','completed' if m=='test/complete' else 'interrupted');versions[key]+=1
            active=None;event('turn/completed',{'threadId':key,'turn':turn})
    elif m=='test/external': external(p.get('threadId','daily-a'))
    elif m=='test/fail-read': fail_read=p['enabled']
    elif m=='test/logs': result={'sent':logs}
    print(json.dumps({'id':r['id'], **({'error':error} if error else {'result':result})}),flush=True)

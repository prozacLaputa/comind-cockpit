#!/usr/bin/python3
# Test fixture only. Never bundled or used by the production application.
import sys,json,time,tempfile,os,atexit,re,subprocess
from pathlib import Path
fixture=tempfile.TemporaryDirectory(prefix="cockpit-protocol-")
atexit.register(fixture.cleanup)
rollout=os.path.join(fixture.name,"rollout.jsonl")
open(rollout,"w").close()
deleted=False
thread={'id':'11111111-1111-4111-8111-111111111111','name':'重命名的驾驶舱','preview':'Old prompt','cwd':'/fixture','updatedAt':123,'model':'fixture-model','reasoningEffort':'medium','historyMode':'paginated','path':rollout}
quota_reads=0
turn_count=0
history_fixture=False
turn_started=None
include_timing=True
organization_job=None
def event(method,params):
 print(json.dumps({'method':method,'params':params}),flush=True)
def complete(status='completed'):
 event('item/agentMessage/delta',{'threadId':thread['id'],'turnId':'run','itemId':'reply','delta':'实时'})
 event('item/agentMessage/delta',{'threadId':thread['id'],'turnId':'run','itemId':'reply','delta':'回复'})
 event('turn/completed',{'threadId':thread['id'],'turn':dict(id='run',status=status,**({'startedAt':turn_started,'completedAt':turn_started+12.34,'durationMs':12340} if include_timing else {}))})
for line in sys.stdin:
 try:r=json.loads(line)
 except Exception:continue
 if 'id' not in r:continue
 method=r.get('method');p=r.get('params',{});result={}
 if not method:
  if r.get('id')=='questions':
   assert r['result']=={'answers':{'route':{'answers':['先测试']},'note':{'answers':['保留旧版本']}}}
   complete()
  if r.get('id')=='organization-approval':
   if r['result']['decision']=='accept':
    tool,repo,identity=organization_job
    root=Path(repo).resolve()
    assert root.name.startswith('organization-') or root.name=='CoMindSourcesPreview-sources', 'synthetic roots only'
    config=json.loads((root/'.local/knowledge-sources.json').read_text()); notes=Path(config['notes_root']).resolve()
    assert notes.is_relative_to(root), 'no real notes'
    run=json.loads((notes/'.comind/consolidation/cockpit-runs'/f'{identity}.json').read_text())
    def bridge(args,payload=None):
     response=subprocess.run([sys.executable,'-B',tool,'--repo',repo,*args],input=json.dumps(payload,ensure_ascii=False) if payload is not None else '',text=True,capture_output=True,check=True)
     return json.loads(response.stdout)
    first=run['targets'][0]; before=bridge(['read',first['reference']])['text']
    routing=bridge(['organization-instructions',identity])
    rule=next((t for t in routing['targets'] if t['reference']==first['reference']),None)
    patch={'old':before,'new':before+'\n\n## 待核对\n- 合成核对：是否每周两次？\n\n本人确认的合成增量。'}
    if rule: patch['categories']=[next(iter(rule['categories']))]
    bridge(['organization-patch',identity,first['reference'],'--expected-sha256',first['sha256']],patch)
    bridge(['organization-complete',identity],{'unchanged':[t['reference'] for t in run['targets'][1:]]})
   complete()
  if r.get('id')=='approval':
   assert r['result']['decision']=='decline'
   complete()
  continue
 if method=='thread/delete':
  if p.get('threadId')==thread['id']:
   deleted=True
   if os.path.exists(rollout):os.remove(rollout)
 if method in ['thread/start','thread/resume']:
  if method=='thread/start':
   deleted=False
   if os.path.exists(rollout):os.remove(rollout)
  if method=='thread/resume' and turn_count==0: raise AssertionError('new thread must not resume before first turn')
  result={'thread':thread,'model':thread['model'],'reasoningEffort':thread['reasoningEffort']}
 if method=='turn/start':
  assert p['sandboxPolicy']['type']=='readOnly' and p['approvalPolicy']=='on-request'
  if p['input'][0]['text']=='fixture-model-choice':
   assert p['model']=='fixture-fast' and p['effort']=='low'
  if p['input'][0]['text']=='fixture-model-inherit':
   assert 'model' not in p and 'effort' not in p
  if p.get('model'):thread['model']=p['model']
  if p.get('effort'):thread['reasoningEffort']=p['effort']
  picked=[x for x in p['input'] if x['type']=='skill']
  if picked:
   assert p['approvalsReviewer']=='user'
   assert len(picked)==len({x['path'] for x in picked})
   assert all(x['name']=='polish' and x['path'] in ['/fixture/skills/polish/SKILL.md','/fixture/repo/polish/SKILL.md'] for x in picked)
   assert all(set(x)=={'type','name','path'} for x in picked)
  if p['input'][0]['text']=='fixture-explicit-skill':
   assert len(picked)==1 and picked[0]['path']=='/fixture/skills/polish/SKILL.md'
  open(rollout,'w').close()
  turn_count+=1
  turn_started=time.time()
  include_timing=p['input'][0]['text']!='fixture-local-time'
  result={'turn':dict(id='run',status='inProgress',**({'startedAt':turn_started} if include_timing else {}))}
 if method=='turn/interrupt':result={}
 if method=='initialize':
  sys.stdout.write(json.dumps({'id':r['id'],'method':'test/serverRequest','params':{}})+'\n');sys.stdout.flush()
 if method=='account/read':result={'account':{'type':'chatgpt','planType':'plus'}}
 if method=='config/read':result={'config':{'model':'fixture-model','model_reasoning_effort':'medium'}}
 if method=='model/list':
  result={'data':[{'model':'fixture-model','displayName':'Fixture Pro','description':'用于检查模型继承','hidden':False,'isDefault':True,'defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':e} for e in ['low','medium','high']]}] if not p.get('cursor') else [{'model':'fixture-fast','displayName':'Fixture Fast','description':'用于检查下一条切换','hidden':False,'isDefault':False,'defaultReasoningEffort':'low','supportedReasoningEfforts':[{'reasoningEffort':'low'}]}], 'nextCursor':None if p.get('cursor') else 'models-page-2'}
 if method=='skills/list':
  cwd=p['cwds'][0]
  if cwd=='/fixture/skills-slow':continue
  skills=[{'name':'polish','description':'整理表达，保留原意','interface':{'displayName':'文字润色','shortDescription':'整理表达，保留原意'},'path':'/fixture/skills/polish/SKILL.md','scope':'user','enabled':True,'pluginId':None},
          {'name':'polish','description':'项目专用规范','path':'/fixture/repo/polish/SKILL.md','scope':'repo','enabled':True,'pluginId':None},
          {'name':'disabled-tool','description':'已停用的测试技能','path':'/fixture/skills/disabled/SKILL.md','scope':'user','enabled':False,'pluginId':None}]
  result={'data':[{'cwd':cwd,'skills':[] if cwd=='/fixture/skills-empty' else skills,'errors':[]}]}
 if method=='account/rateLimits/read':result={'rateLimits':{},'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':30,'windowDurationMins':10080,'resetsAt':12345},'secondary':None}}}
 if method=='thread/list' and p.get('searchTerm')=='fixture-external-rename':
  thread['name']='来自 Codex 的名称'
  event('thread/name/updated',{'threadId':thread['id'],'threadName':thread['name']})
 if method=='thread/list' and p.get('searchTerm')=='fixture-history':history_fixture=True
 if method=='thread/list':result={'data':[] if deleted or p.get('searchTerm') else [thread],'nextCursor':None}
 if method=='thread/read':
  if p.get('threadId')=='slow':continue
  result={'thread':thread}
 if method=='thread/turns/list':result={'data':[{'id':'turn','status':'completed','startedAt':1700000000,'completedAt':1700000012,'durationMs':12340,'items':[{'type':'userMessage','content':[{'type':'text','text':'Hello'}]},{'type':'agentMessage','text':'你好'}]}],'nextCursor':None}
 if method=='thread/turns/list' and history_fixture:
  numbers=range(21,1,-1) if not p.get('cursor') else [2,1,0]
  result={'data':[{'id':f'turn-{i}','status':'completed','items':[{'id':f'user-{i}','type':'userMessage','content':[{'type':'text','text':f'question {i}'}]},{'id':f'agent-{i}','type':'agentMessage','text':f'answer {i}'}]} for i in numbers], 'nextCursor':'older' if not p.get('cursor') else None}
 if method=='thread/name/set':
  assert p.get('name','').strip(), 'empty names must be rejected before RPC'
  if p['name']=='fixture-rename-timeout':continue
  if p.get('threadId')==thread['id'] and p['name']!='fixture-rename-error':
   thread['name']=p['name'];open(rollout,'a').close()
   event('thread/name/updated',{'threadId':thread['id'],'threadName':thread['name']})
 response={'id':r['id'],'result':result}
 if method=='skills/list' and cwd=='/fixture/skills-error':response={'id':r['id'],'error':{'code':-32601,'message':'fixture skills unavailable'}}
 if method=='thread/name/set' and p['name']=='fixture-rename-error':response={'id':r['id'],'error':{'code':-1,'message':'fixture rename failure'}}
 if method=='account/rateLimits/read':
  quota_reads+=1
  if quota_reads==2:response={'id':r['id'],'error':{'code':-1,'message':'temporary quota failure'}}
 if method=='thread/delete' and p.get('threadId')=='occupied':response={'id':r['id'],'error':{'code':-32600,'message':'thread occupied already has an active writer'}}
 if p.get('threadId')=='missing':response={'id':r['id'],'error':{'code':-1,'message':'not found'}}
 data=(json.dumps(response,ensure_ascii=False)+'\n').encode()
 sys.stdout.buffer.write(data[:7]);sys.stdout.buffer.flush();time.sleep(.002)
 sys.stdout.buffer.write(data[7:]);sys.stdout.buffer.flush()

 if method=='turn/start' and p.get('outputSchema'):
  if 'personality' in p['outputSchema'].get('required',[]):
   request_text=p['input'][0]['text']
   payload={'responsibility':'负责整理方案与阶段成果','personality':'简洁、耐心，明确区分事实和建议','skills':'需求拆解、方案比较和证据整理','workingStyle':'先澄清目标，再给出可检查的小步骤','boundaries':'发布、删除或扩大访问前先询问'}
   if 'fixture-invalid-profile' in request_text:payload['skills']=''
  else:
   payload={k:[] for k in ['current','completed','next','uncertain']}
   payload['completed']=[{'text':'已完成连接测试','sources':['S1']}]
   payload['memories']=[{'topic':'声音偏好','text':'桌面设备默认静音','category':'preference','sources':['S1']}]
  event('item/completed',{'threadId':thread['id'],'item':{'type':'agentMessage','id':'summary','text':json.dumps(payload,ensure_ascii=False)}})
  event('turn/completed',{'threadId':thread['id'],'turn':{'id':'run','status':'completed'}})
 elif method=='turn/start':
  event('turn/started',{'threadId':thread['id'],'turn':result['turn']})
  event('item/agentMessage/delta',{'threadId':thread['id'],'turnId':'stale-turn','itemId':'stale','delta':'must not appear'})
  event('turn/completed',{'threadId':thread['id'],'turn':{'id':'stale-turn','status':'failed','durationMs':999999}})
  if p['input'][0]['text'].startswith('fixture-error-'):
   scenario=p['input'][0]['text'].removeprefix('fixture-error-')
   event('error',{'threadId':thread['id'],'turnId':'run','willRetry':scenario not in ['terminal-success','missing-final-error'],'error':{'message':'fixture terminal 429','codexErrorInfo':{'responseTooManyFailedAttempts':{'httpStatusCode':429}}}})
   status='failed' if scenario in ['retry-failed','missing-final-error'] else 'interrupted' if scenario=='retry-interrupted' else 'completed'
   turn={'id':'run','status':status}
   if scenario=='retry-failed':turn['error']={'message':'fixture final 429','codexErrorInfo':{'responseTooManyFailedAttempts':{'httpStatusCode':429}}}
   event('turn/completed',{'threadId':thread['id'],'turn':turn})
  elif '[驾驶舱整理请求 · ' in p['input'][0]['text']:
   text=p['input'][0]['text']
   identity=re.search(r'\[驾驶舱整理请求 · ([0-9a-fA-F-]{36})\]',text).group(1)
   tool,repo=re.search(r"python3 -B '([^']+bridge.py)' --repo '([^']+)'",text).groups()
   organization_job=(tool,repo,identity)
   print(json.dumps({'id':'organization-approval','method':'item/commandExecution/requestApproval','params':{'threadId':thread['id'],'turnId':'run','itemId':'organization-command','command':'合成验收：通过 bridge.py 写回选定原件并核对回执','reason':'仅隔离笔记'}}),flush=True)
  elif p['input'][0]['text']=='fixture-questions':
   print(json.dumps({'id':'questions','method':'item/tool/requestUserInput','params':{'threadId':thread['id'],'turnId':'run','itemId':'question-item','isBlocking':True,'questions':[{'id':'route','header':'路线','question':'先做什么？','options':[{'label':'先测试','description':'验证合成数据'}]},{'id':'note','header':'备注','question':'如何保留历史？'}]}}),flush=True)
  elif turn_count==1:
   print(json.dumps({'id':'approval','method':'item/commandExecution/requestApproval','params':{'threadId':thread['id'],'turnId':'run','itemId':'command','command':'echo fixture','reason':'fixture approval'}}),flush=True)
 if method=='turn/interrupt':complete('interrupted')

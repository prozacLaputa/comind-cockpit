#!/usr/bin/python3
"""隔离的只读检索与恢复协议夹具，不连接模型。"""
import json, sys

def thread(key):
    number = int(key.split('-')[-1]) if key.startswith('activity-') else 0
    return dict(id=key, name='fixture '+key, cwd='/fixture', path=__file__, updatedAt=10000 if number == 0 else number,
                historyMode='paginated', status={'type': 'idle'})

for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request or 'method' not in request:
        continue
    method, p = request['method'], request.get('params', {})
    result = {}
    if method == 'account/read': result = {'account': {'type': 'chatgpt', 'planType': 'fixture'}}
    if method == 'thread/list': result = {'data': [], 'nextCursor': None}
    if method == 'thread/read': result = {'thread': thread(p['threadId'])}
    if method == 'thread/turns/list':
        result = {'data': [{'id': 'turn-'+p['threadId'], 'status': 'completed', 'items': [
            {'id': 'q', 'type': 'userMessage', 'content': [{'type': 'text', 'text': 'needle '+p['threadId']}]},
            {'id': 'a', 'type': 'agentMessage', 'text': 'fixture answer'}]}], 'nextCursor': None}
        if p['threadId']=='context-wrapper':
            result['data'][0]['items'][0]['content'][0]['text']='当前阵地：合成\nSTALE_INJECTED_CONTEXT\n\n---\n\n本次需求：\nACTUAL_USER_INPUT'
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)

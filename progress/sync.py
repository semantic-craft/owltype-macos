#!/usr/bin/env python3
"""Refresh the shared input-alignment view from GitHub; never dispatch agents."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPO = 'semantic-craft/owltype-macos'
GROUPS = {'pinyin': list(range(281, 294)), 'wubi': list(range(295, 305))}

def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--teslahub', type=Path, help='Existing TeslaHub checkout with board/cli.mjs')
    parser.add_argument('--hub-out', type=Path, help='Local generated board directory, not source')
    args = parser.parse_args()
    if bool(args.teslahub) != bool(args.hub_out):
        parser.error('--teslahub and --hub-out must be supplied together')
    config_path = ROOT / 'progress/progress.json'
    config = json.loads(config_path.read_text())
    numbers = [280, 294] + sum(GROUPS.values(), [])
    fields = """number title url body state stateReason updatedAt
      assignees(first:100) {nodes {login} pageInfo {hasNextPage}}
      labels(first:100) {nodes {name} pageInfo {hasNextPage}}
      comments(first:100) {nodes {databaseId body createdAt author {login}} pageInfo {hasNextPage}}
      parent {number}
      blockedBy(first:100) {nodes {number state} pageInfo {hasNextPage}}
      subIssues(first:100) {nodes {number} pageInfo {hasNextPage}}"""
    issue_query = ' '.join(f'i{n}:issue(number:{n}) {{{fields}}}' for n in numbers)
    query = '{repository(owner:"semantic-craft",name:"owltype-macos"){defaultBranchRef{name target{oid}} '+issue_query+"""
      pullRequests(first:100,states:OPEN) {nodes {number title url body state updatedAt headRefOid mergedAt
        labels(first:100){nodes{name} pageInfo{hasNextPage}}
        comments(first:100){nodes{databaseId body createdAt author{login}} pageInfo{hasNextPage}}
        files(first:100){nodes{path} pageInfo{hasNextPage}}
        commits(last:100){nodes{commit{committedDate}} pageInfo{hasPreviousPage}}
      } pageInfo{hasNextPage}}
      releases(first:10,orderBy:{field:CREATED_AT,direction:DESC}){nodes{databaseId tagName isDraft isPrerelease publishedAt}}
    }}"""
    result = json.loads(run('gh','api','graphql','-f','query='+query))
    if result.get('errors'):
        raise RuntimeError('GraphQL snapshot failed; prior page preserved')
    remote = result['data']['repository']
    def complete(value):
        if isinstance(value, dict):
            if value.get('hasNextPage') or value.get('hasPreviousPage'):
                raise RuntimeError('Snapshot exceeds bounded query; paginate this connection before publishing')
            for child in value.values(): complete(child)
        elif isinstance(value,list):
            for child in value: complete(child)
    complete(remote)
    data = {}
    for n in numbers:
        issue = remote['i'+str(n)]
        if not issue: raise RuntimeError(f'Missing issue #{n}')
        issue['state'] = issue['state'].lower()
        issue['updated_at'] = issue['updatedAt']
        issue['assignees'] = issue['assignees']['nodes']
        issue['labels'] = issue['labels']['nodes']
        issue['comments'] = [dict(c,id=c['databaseId']) for c in issue['comments']['nodes']]
        deps=[dict(d,state=d['state'].lower()) for d in issue['blockedBy']['nodes']]
        data[n]=(issue,deps)
    from datetime import datetime, timezone
    observed = datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z')
    prs=remote['pullRequests']['nodes']
    for pr in prs:
        for key in ('labels','comments','files'): pr[key]=pr[key]['nodes']
        pr['comments']=[dict(c,id=c['databaseId']) for c in pr['comments']]
        pr['commits']=[c['commit'] for c in pr['commits']['nodes']]
    config['tracked']['issues']=numbers
    config['observed_at']=observed
    config['facts']={
      'main':remote['defaultBranchRef']['target']['oid'], 'default_branch':remote['defaultBranchRef']['name'],
      'pulls':[], 'open_pulls':sorted([{'number':p['number'],'head':p['headRefOid']} for p in prs
        if not (p['files'] and all(f['path'].startswith('progress/') for f in p['files']))],key=lambda x:x['number']),
      'issues':[{'number':n,'state':data[n][0]['state'],'reason':data[n][0]['stateReason'].lower() if data[n][0]['stateReason'] else None,'updated_at':data[n][0]['updated_at']} for n in sorted(numbers)],
      'releases':[{'id':r['databaseId'],'tag':r['tagName'],'draft':r['isDraft'],'prerelease':r['isPrerelease'],'published_at':r['publishedAt']} for r in remote['releases']['nodes']]}
    sections = [{'id':'contract','title':'共同入口与领取','items':[{
        'id':'coordination','title':'GitHub 为真源；两个输入方案共用设施','status':'in_progress',
        'summary':'本页是带观察时间的快照。阻塞按 GitHub 原生依赖计算；负责人只表示 GitHub 指派，不冒充 agent 会话。工单关闭不自动等于产品验收。',
        'next':'按 docs/input-alignment.md 使用 TeslaHub 唯一领取入口；不要从静态 HTML 启动第二个执行器。刷新：python3 progress/sync.py。',
        'evidence':[{'kind':'issue','ref':280,'note':'拼音规格与已存在工单'},{'kind':'issue','ref':294,'note':'五笔规格与十张子票'},{'kind':'file','ref':'docs/input-alignment.md','note':'共用依赖、领取及同步协议'}]}]}]
    for group, members in GROUPS.items():
        items=[]
        for n in members:
            issue, deps = data[n]
            blockers=[d['number'] for d in deps if d['state'] != 'closed']
            owners=[a['login'] for a in issue['assignees']]
            labels={x['name'] for x in issue['labels']}
            status = 'unverified' if issue['state']=='closed' else 'in_progress' if owners or labels & {'status:doing','status:in-review'} else 'blocked' if blockers or labels & {'on-hold','status:waiting'} else 'planned'
            items.append({'id':f'issue-{n}','title':f'#{n} {issue["title"]}','status':status,
              'summary':f'GitHub: {issue["state"]}；负责人：{", ".join(owners) or "未指派"}；未关闭前置：{", ".join("#"+str(d) for d in blockers) or "无"}。',
              'next':'核对工单完成证据。' if issue['state']=='closed' else '沿用当前执行会话，勿重复领取。' if owners else '等待前置完成，复用其成果。' if blockers else '读取工单和开放 PR，经共享领取入口核实后领取。',
              'evidence':[{'kind':'issue','ref':n,'note':'范围、当前状态和证据原件'}]})
        sections.append({'id':group,'title':'拼音对齐（现有执行线）' if group=='pinyin' else '五笔对齐（本轮工单）','items':items})
    config['sections']=sections
    config['inputs']=['docs/input-alignment.md','progress/sync.py','progress/teslahub.mjs']
    config_path.write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    subprocess.run([sys.executable,'progress/progress.py','render'],cwd=ROOT,check=True)
    subprocess.run([sys.executable,'progress/progress.py','check'],cwd=ROOT,check=True)
    if args.teslahub:
        # One complete scoped observation feeds both projections. Bodies stay in ignored output.
        args.hub_out.mkdir(parents=True,exist_ok=True)
        fixture=args.hub_out.resolve()/'github-snapshot.json'
        snapshot={'observed_at':observed,'repositories':{'owltype-macos':{
          'issues':[data[n][0] for n in sum(GROUPS.values(),[]) if data[n][0]['state']=='open'],
          'open':[p for p in prs if set(map(int,re.findall(r'(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)',p['body'] or '')+re.findall(r'\(#(\d+)\)',p['title']))) & set(sum(GROUPS.values(),[]))], 'merged':[]}}}
        fixture.write_text(json.dumps(snapshot,ensure_ascii=False))
        subprocess.run(['node',str(ROOT/'progress/teslahub.mjs'),str(args.teslahub.resolve()),str(fixture),str(args.hub_out.resolve())],cwd=ROOT,check=True)
    print('Refreshed 13 pinyin and 10 wubi tickets; no dispatch or issue mutation.')

if __name__ == '__main__':
    main()

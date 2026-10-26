// Reuse TeslaHub's renderer; derive this scoped view from native dependency facts.
import fs from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const [home, snapshotFile, output] = process.argv.slice(2);
if (!home || !snapshotFile || !output) throw Error('Usage: teslahub.mjs HOME SNAPSHOT OUTPUT');
const {buildBoard, COLUMNS} = await import(pathToFileURL(path.resolve(home,'board/rules.mjs')));
const {render} = await import(pathToFileURL(path.resolve(home,'board/render.mjs')));
const snapshot=JSON.parse(await fs.readFile(snapshotFile,'utf8'));
const projects=JSON.parse(await fs.readFile(path.resolve(home,'board/projects.json'),'utf8'));
const board=buildBoard(snapshot,projects);
const issues=snapshot.repositories['owltype-macos'].issues;
for(const section of board.sections) for(const item of section.items) {
  if(item.type!=='Issue') continue;
  const issue=issues.find(i=>i.number===item.number);
  const deps=issue.blockedBy.nodes.filter(i=>i.state!=='CLOSED').map(i=>i.number);
  const assignees=issue.assignees.map(i=>i.login);
  item.blocked_by=deps;
  item.github_assignees=assignees;
  if(assignees.length) {
    item.column='Doing'; item.pipeline='在做'; item.status='in_progress'; item.owners=assignees;
    item.summary=`GitHub 已指派：${assignees.join(', ')}；执行会话以原工单为准`;
    item.next='沿用已有会话，不重复领取';
  } else if(deps.length) {
    item.column='Waiting'; item.pipeline='等待前置 '+deps.map(n=>'#'+n).join('、'); item.status='blocked';
    item.blocked=true; item.summary=`未关闭前置：${deps.map(n=>'#'+n).join('、')}`;
    item.next='等待前置完成，领取时再次实时核对';
  }
}
const items=board.sections.flatMap(s=>s.items);
board.sections=COLUMNS.map((title,index)=>({id:`column-${index}`,title,items:items.filter(i=>i.column===title)}));
board.title='Owltype · 拼音与五笔共享看板（GitHub 依赖快照）';
board.scope={issues:issues.map(i=>i.number),note:'只含两条对齐执行线；不表示整个项目。领取使用共用协调账本，未自动派工。'};
await fs.mkdir(output,{recursive:true});
await fs.writeFile(path.join(output,'board.json'),JSON.stringify(board,null,2)+'\n');
await fs.writeFile(path.join(output,'index.html'),render(board));
console.log(JSON.stringify({tickets:items.length,columns:Object.fromEntries(board.sections.map(s=>[s.title,s.items.length]))}));

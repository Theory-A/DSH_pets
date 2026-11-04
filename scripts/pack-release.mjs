// Maintainer-only packaging: GitHub uses the local GIF; npm needs a public URL.
// No install/publish lifecycle hooks or third-party dependencies.
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, copyFileSync, chmodSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
const root=fileURLToPath(new URL('../',import.meta.url));
const manifest=JSON.parse(readFileSync(join(root,'package.json'),'utf8'));
const out=join(root,'artifacts');mkdirSync(out,{recursive:true});
const run=(args,cwd)=>JSON.parse(execFileSync('npm',args,{cwd,encoding:'utf8',stdio:['ignore','pipe','inherit']}));
const [inventory]=run(['pack','--dry-run','--ignore-scripts','--json'],root);
const stage=mkdtempSync(join(out,'npm-stage-'));
for(const {path} of inventory.files){
  const source=resolve(root,path),target=resolve(stage,path);
  assert.ok(source.startsWith(root) && target.startsWith(stage+'/'));
  mkdirSync(dirname(target),{recursive:true});copyFileSync(source,target);
  chmodSync(target,statSync(source).mode&0o777);
}
const preview=`https://cdn.jsdelivr.net/npm/${manifest.name}@${manifest.version}/docs/pets-demo.gif`;
const readme=readFileSync(join(stage,'README.md'),'utf8');
assert.ok(readme.includes('](<docs/pets-demo.gif>)'));
writeFileSync(join(stage,'README.md'),readme.replace('](<docs/pets-demo.gif>)',`](<${preview}>)`));
const result=run(['pack','--ignore-scripts','--json','--pack-destination',out],stage);
writeFileSync(join(out,'pack-readme-result.json'),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify({package:result[0].id,artifact:join(out,result[0].filename),bytes:result[0].size,preview,note:'The public GIF URL becomes available after this package version is published.'},null,2));

import http from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
const root=process.cwd();
const types={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml'};
const server=http.createServer(async(req,res)=>{
  let file;
  try{file=decodeURIComponent(new URL(req.url,'http://localhost').pathname);}catch{res.writeHead(400);res.end();return;}
  if(file==='/')file='/index.html';
  const full=path.resolve(root,'.'+file);
  if(!full.startsWith(root+path.sep)||!['/index.html','/app.js','/style.css','/icon.svg','/config.js'].includes(file)){res.writeHead(404);res.end();return;}
  try{res.writeHead(200,{'Content-Type':types[path.extname(full)]||'application/octet-stream','Cache-Control':'no-store'});res.end(await readFile(full));}catch{res.writeHead(404);res.end();}
});
server.listen(4173,'127.0.0.1',()=>process.stdout.write('Local: http://127.0.0.1:4173\n'));

const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');
let ts;
try { ts = require('typescript'); } catch {
  const sdkTs = process.env.WEIBO_TYPESCRIPT;
  if (!sdkTs) throw new Error('Run npm install or set WEIBO_TYPESCRIPT to a local typescript module');
  ts = require(sdkTs);
}
module.exports = function load(relative, mocks = {}) {
  const filename = path.resolve(__dirname, '..', relative);
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const m = new Module(filename, module);
  m.filename = filename;
  m.paths = module.paths;
  const originalRequire = m.require.bind(m);
  m.require = id => Object.hasOwn(mocks, id) ? mocks[id] : originalRequire(id);
  m._compile(output, filename);
  return m.exports;
};

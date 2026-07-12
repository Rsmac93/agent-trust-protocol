const solc = require('solc');
const fs = require('fs');
const path = require('path');

const files = ['AGTToken.sol','Emission.sol','Staking.sol','AgentRegistry.sol','AgentRegistryV2.sol','TeamVesting.sol'];
const sources = {};
files.forEach(f => sources['contracts/'+f] = { content: fs.readFileSync('contracts/'+f,'utf8') });

function findImports(p) {
  const full = p.startsWith('@openzeppelin') ? path.join('node_modules', p) : p;
  try { return { contents: fs.readFileSync(full, 'utf8') }; }
  catch (e) { return { error: 'not found: ' + p }; }
}

const input = { language: 'Solidity', sources,
  settings: { optimizer: { enabled: true, runs: 200 }, outputSelection: { '*': { '*': ['abi','evm.bytecode.object'] } } } };

const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
let fail = false;
(out.errors || []).forEach(e => { if (e.severity === 'error') { fail = true; console.log('ERROR:', e.formattedMessage); } });
if (!fail) {
  Object.keys(out.contracts).filter(k => k.startsWith('contracts/')).forEach(k => {
    Object.keys(out.contracts[k]).forEach(c => console.log('COMPILED:', c, '| bytecode bytes:', out.contracts[k][c].evm.bytecode.object.length/2));
  });
}

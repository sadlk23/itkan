// Summarize the saved PERF_PROBE log without treating a bounded run as leak proof.
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
const input = process.argv[2] || 'remaining-soak-probe.log';
const output = process.argv[3] || 'remaining-probe-summary.json';
const lines = fs.readFileSync(path.join(root, input), 'utf8').split(/\r?\n/);
const events = lines.filter(line => line.includes('PERF_PROBE ')).map(line => JSON.parse(line.split('PERF_PROBE ')[1]));
const memory = events.filter(e => e.event === 'memory');
const soakMemory = memory.filter(e => e.phase.startsWith('soak-'));
const summary = {
  device: 'Android API36 x64 emulator; profile build',
  scenarios: events.filter(e => e.event === 'scenario'),
  soak: events.filter(e => e.event === 'soak'),
  memory,
  soakRssMiB: soakMemory.map(e => ({phase: e.phase, rssMiB: +(e.processRssBytes / 1048576).toFixed(2)})),
  cacheBytes: [...new Set(memory.map(e => e.imageCacheBytes))],
  complete: events.findLast(e => e.event === 'complete') ?? null,
  limits: 'Synthetic representative images and icons; no real user photos/DB. A bounded repeated run does not establish long-term leak freedom or physical-device performance.',
};
fs.writeFileSync(path.join(root, output), JSON.stringify(summary, null, 2));
console.log(JSON.stringify({scenarios: summary.scenarios.length, soakRounds: summary.soak.length, complete: summary.complete, cacheBytes: summary.cacheBytes}));

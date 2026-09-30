// Exercise the patched QML's actual JavaScript with controlled process completion.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(process.argv[2],
  'shell/plugins/services/nightlight/Service.qml'), 'utf8');
function body(marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, marker);
  const open = source.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth; end++) {
    assert.ok(end < source.length);
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  return source.slice(open + 1, end - 1);
}
function service(enabled = false) {
  const root = {
    nightTemperature: 4000, dayTemperature: 6500, stateLoaded: true,
    temperature: enabled ? 4000 : 6500, requestedTemperature: null,
    refreshPending: false, hasPendingTemperature: false, pendingTemperature: 0,
    applyProcess: {running: false}, statusProbe: {running: false},
    NightlightModel: {isNightlight: t => t !== null && t < 6500},
  };
  Object.defineProperty(root, 'enabled', {get: () => root.stateLoaded && root.NightlightModel.isNightlight(root.temperature)});
  root.root = root;
  const context = vm.createContext(root);
  for (const [name, args] of [['refresh', ''], ['setNightlight', 'value'],
    ['toggle', ''], ['applyTemperature', 'temp'], ['runApply', 'temp']]) {
    vm.runInContext(`function ${name}(${args}) {${body(`function ${name}(`)}}`, context);
  }
  const call = (marker, args = {}) => {
    Object.assign(root, args);
    vm.runInContext(`(function() {${body(marker)}})()`, context);
  };
  root.ipcToggle = () => vm.runInContext(`(function() {${body('function toggle(): string')}})()`, context);
  root.finishApply = () => {
    root.applyProcess.running = false;
    call('onExited: function()');
  };
  root.finishProbe = (temperature, exitCode = 0) => {
    call('onStreamFinished:', {text: JSON.stringify({temperature})});
    root.statusProbe.running = false;
    call('onExited: function(exitCode)', {exitCode});
  };
  root.target = () => Number(root.applyProcess.command[2]);
  return root;
}
for (const initial of [false, true]) {
  for (const count of [2, 3, 4, 5]) {
    const s = service(initial);
    for (let i = 0; i < count; i++) {
      const expected = i % 2 === 0 ? !initial : initial;
      assert.equal(s.ipcToggle(), expected ? 'enabled' : 'disabled');
      assert.equal(s.enabled, initial, 'indicator must remain confirmed');
    }
    s.finishApply();
    const expected = count % 2 === 0 ? initial : !initial;
    assert.equal(s.target(), expected ? 4000 : 6500);
    s.finishApply();
    s.finishProbe(s.target());
    assert.equal(s.enabled, expected);
    assert.equal(s.requestedTemperature, null);
  }
}
// A click after apply exit but before its status probe must still invert intent.
{
  const s = service();
  s.toggle(); s.finishApply();
  s.toggle();
  assert.equal(s.target(), 6500);
  s.finishProbe(4000);
  assert.equal(s.requestedTemperature, 6500);
  s.finishApply(); s.finishProbe(6500);
  assert.equal(s.enabled, false);
}
// An older probe completing after apply must cause a fresh probe, not discard intent.
{
  const s = service();
  s.refresh(); s.toggle(); s.finishApply(); s.finishProbe(6500);
  assert.equal(s.statusProbe.running, true);
  assert.equal(s.requestedTemperature, 4000);
  s.finishProbe(4000);
  assert.equal(s.requestedTemperature, null);
}
// Failed apply/probe must release intent so a retry uses the confirmed state.
for (const exitCode of [0, 1]) {
  const s = service();
  s.toggle(); s.finishApply(); s.finishProbe(6500, exitCode);
  assert.equal(s.enabled, false);
  assert.equal(s.requestedTemperature, null);
  s.toggle(); assert.equal(s.target(), 4000);
}
// Explicit enable/disable and toggles share the same pending intent.
{
  const s = service();
  s.setNightlight(true); s.setNightlight(false); s.toggle();
  s.finishApply(); assert.equal(s.target(), 4000);
  s.finishApply(); s.finishProbe(4000);
  s.refresh(); s.finishProbe(6500); // external change/reload
  s.toggle(); assert.equal(s.target(), 4000);
}
console.log('ok - night-light rapid toggles, stale probes, failures, and external changes');

// Run against the staged, patched source via guest/test --source CHECKOUT.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(
  path.join(process.argv[2], 'shell/services/AuthServiceStore.js'), 'utf8');
const store = vm.createContext({});
vm.runInContext(source, store);

// Startup and failed service loads must keep notification content hidden.
assert.equal(store.screenLocked('omarchy.lock'), true);
let destroyed = 0;
const lock = { locked: false, pendingPassword: 'private', destroy() { destroyed++; } };
store.put('omarchy.lock', lock);
assert.equal(store.screenLocked('omarchy.lock'), false);
lock.locked = true;
assert.equal(store.screenLocked('omarchy.lock'), true);
lock.locked = false;
assert.equal(store.screenLocked('omarchy.lock'), false);
assert.equal(typeof store.screenLocked('omarchy.lock'), 'boolean');

// Disabling, removing, or replacing the lock must never retain an unlocked state.
store.destroy('omarchy.lock');
assert.equal(destroyed, 1);
assert.equal(store.screenLocked('omarchy.lock'), true);
store.put('omarchy.lock', { destroy() {} });
assert.equal(store.screenLocked('omarchy.lock'), true);
store.put('omarchy.lock', lock);
assert.equal(store.screenLocked('omarchy.lock'), false);
store.destroyAll();
assert.equal(store.screenLocked('omarchy.lock'), true);

// Another component's import remains isolated from the host's private store.
store.put('omarchy.lock', lock);
const pluginStore = vm.createContext({});
vm.runInContext(source, pluginStore);
assert.equal(pluginStore.has('omarchy.lock'), false);
assert.equal(pluginStore.screenLocked('omarchy.lock'), true);
assert.equal(store.screenLocked('omarchy.lock'), false);
console.log('ok - private lock state covers startup, lock/unlock, replacement, teardown, and isolated imports');

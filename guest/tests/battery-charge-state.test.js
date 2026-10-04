// Exercise the reviewed upstream power model after the factory/boot patch.
const assert = require('node:assert/strict');
const model = require(process.argv[2]);
const states = { Charging: 1, Discharging: 2, FullyCharged: 4, PendingCharge: 5 };

function battery(overrides = {}) {
  return { isPresent: true, percentage: 0.57, state: states.Charging, ...overrides };
}

const chargingIcon = model.batteryIcon(battery({ changeRate: 12 }), false, states);
const unpluggedIcon = model.batteryIcon(battery({ state: states.Discharging }), true, states);
assert.notEqual(chargingIcon, unpluggedIcon);

// UPower suppresses watts temporarily after AC changes. Missing or slow
// estimates must not turn the host's Charging state into a false charge hold.
for (const values of [
  {}, { changeRate: 0 }, { changeRate: 0.1 }, { changeRate: 0.2 },
  { changeRate: 12 }, { changeRate: 12, timeToFull: 8 * 60 * 60 },
  { changeRate: 0, timeToFull: 10 * 60 * 60 },
]) {
  const device = battery(values);
  assert.equal(model.chargeThresholdActive(device, false, states), false);
  assert.equal(model.modeLabel(device, false, states), 'Charging');
  assert.equal(model.batteryIcon(device, false, states), chargingIcon);
}

// Preserve genuine holds and the existing partial-full threshold behavior.
for (const state of [states.PendingCharge, states.FullyCharged]) {
  const device = battery({ state, changeRate: 0 });
  assert.equal(model.chargeThresholdActive(device, false, states), true);
  assert.equal(model.modeLabel(device, false, states), 'Threshold');
  assert.equal(model.batteryIcon(device, false, states), unpluggedIcon);
}
assert.equal(model.modeLabel(battery({ state: states.FullyCharged, percentage: 1 }), false, states), 'Fully charged');
assert.equal(model.chargeThresholdActive(battery({ state: states.FullyCharged, percentage: 1 }), false, states), false);

// The same live device changes state while its percentage remains fixed.
const device = battery();
for (const [state, onBattery, label, icon] of [
  [states.Discharging, true, 'On battery', unpluggedIcon],
  [states.PendingCharge, false, 'Threshold', unpluggedIcon],
  [states.Charging, false, 'Charging', chargingIcon],
  [states.Discharging, true, 'On battery', unpluggedIcon],
]) {
  device.state = state;
  device.changeRate = 0;
  assert.equal(model.modeLabel(device, onBattery, states), label);
  assert.equal(model.batteryIcon(device, onBattery, states), icon);
}
assert.equal(model.chargeThresholdActive(battery({ isPresent: false }), false, states), false);
assert.equal(model.batteryIcon(battery({ isPresent: false }), false, states), '');
console.log('Battery charge-state model passed');

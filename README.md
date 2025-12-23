# EdgeTX SagComp

**EdgeTX SagComp** is a Lua telemetry utility for EdgeTX users who only have battery voltage (no current sensor) and want a more realistic “no-load” per-cell voltage estimate while flying high-throttle profiles (e.g., 3D aerobatics).

It creates/updates the following telemetry sensors:
- **BatP** — Battery percentage (0–100%), derived from the compensated per-cell voltage using a LiPo voltage→percent table.
- **Sag** — Compensated per-cell voltage (attempts to emulate “rest” voltage under no load).
- **Cell** — Raw measured per-cell voltage (actual pack-voltage-derived per-cell under current load).
- **Ratio** — Compensation ratio (0–100%) applied based on throttle position.

## Why this exists

With only a voltage sensor, high throttle causes voltage sag that can trigger false low-voltage alarms and distort battery percentage. This script models sag behavior and attempts to reconstruct an approximate “no-load” per-cell voltage for more stable alerts and telemetry readouts.

## How it works (high level)

1. **Auto cell-count detection** from pack voltage.
2. **Per-cell raw voltage** computed from the pack voltage telemetry sensor.
3. **OCV-hold (no-load estimate) model**:
   - When entering a load episode, the script locks a reference “rest” voltage.
   - During sustained throttle, it estimates how that reference would slowly decline over time (“decay”), using a learned decay curve.
4. **Sag learning**:
   - Tracks voltage minima during load by throttle buckets.
   - When throttle is reduced and the voltage recovers (plateau detected), it updates:
     - Sag curve per throttle bucket
     - Decay curve
     - Recovery timing parameters
5. **Throttle-based ramp**:
   - Below a low-throttle threshold, compensation is disabled.
   - Between low and mid throttle, compensation ramps in smoothly.
6. **Output rate** matches the source voltage sensor cadence (adaptive), to avoid over-updating and producing excessive SD logging.

## Persistence (per-model)

Learned parameters are saved per EdgeTX model to:

`/SCRIPTS/DATA/SagComp_<ModelName>.dat`

This allows each aircraft/model to retain its own learned sag/decay characteristics across flights.

## Installation

1. Copy the Lua script to the radio SD card:
   - `SCRIPTS/MIXES/`
2. Ensure the data folder exists:
   - `SCRIPTS/DATA/`
3. Enable the script in the EdgeTX model:
   - Model Setup → **Lua Scripts** → add this script (Mixes script section) so it runs continuously.
4. Power the aircraft/receiver so the **source voltage sensor** is actively transmitting.
   - The generated sensors (**BatP/Sag/Cell/Ratio**) are only discoverable after the source voltage sensor is sending data.
5. Run Telemetry Discovery (if needed) and add the new sensors to screens/alerts.

## Configuration

Edit the “User sensor names” section to match the telemetry names:

- `myBatSensorName`  (pack voltage sensor name)
- `myBatPercentName` (output % sensor)
- `mySagCellName`    (output compensated per-cell)
- `myRawCellName`    (output raw per-cell)
- `myThrSourceName`  (throttle input source, e.g. `ch3`)

## Notes / Limitations

- This is an estimation model; it cannot be perfect without a current sensor.
- Results depend on battery condition, wiring resistance, connectors, prop load, ambient temperature, and telemetry update cadence.
- The script attempts to be conservative against impossible values (e.g., compensated > plausible rest).

## Credits

Created by **Itay Sharoni** with use of AI.

## License

Released under the MIT License — see [LICENSE](LICENSE).

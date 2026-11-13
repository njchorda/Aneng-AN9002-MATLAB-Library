# AnengAN9002

A MATLAB class for reading measurements from an ANENG AN9002 Bluetooth multimeter.

The meter is a Bluetooth LE device that advertises as `Bluetooth DMM`. The class connects to it, decodes the packets it sends about three times a second, and returns what is on the LCD as numbers.

## Requirements

- MATLAB R2019b or later with Bluetooth LE support (`ble`, `blelist`)
- A Bluetooth LE adapter
- `AnengAN9002.m` on the MATLAB path

Do **not** pair the meter in Windows Bluetooth settings. It has no standard profile, so pairing fails and can block the connection. If it is listed there, remove it.

## How to use

1. Turn the meter on and enable Bluetooth on it.
2. Connect:

   ```matlab
   dmm = AnengAN9002();                 % finds the first "Bluetooth DMM" (about 5 s)
   dmm = AnengAN9002('FC58FA44F4F3');   % or connect by address, which skips the scan
   ```

3. Read:

   ```matlab
   v = dmm.readValue();            % number in base units, e.g. 0.01234 for 12.34 mV
   [v, unit] = dmm.readValue();    % unit is 'V', 'A', 'Ω', ...
   r = dmm.read();                 % struct with everything on the display
   ```

4. Disconnect:

   ```matlab
   dmm.deInit();
   ```

   `clear dmm` also disconnects.

### Logging and streaming

```matlab
tt = dmm.log(10);                          % record for 10 s, returns a timetable
plot(tt.Time, tt.Scaled)

dmm.start(@(r) disp(r.Display));           % call a function on every reading
dmm.stop();

dmm.start();                               % or just keep dmm.lastReading up to date
x = dmm.lastReading.Scaled;
dmm.stop();
```

## Methods

| Method | What it does |
|---|---|
| `AnengAN9002()` / `AnengAN9002(address)` | Connects to the meter. With no argument it scans for a device named `Bluetooth DMM`. |
| `readValue()` | Waits for the next packet and returns the reading as a number in base units (V, A, Ω, F, Hz, °C, °F). Second output is the base unit. `Inf` on overload, `NaN` if the display is not a number (for example `Auto`). |
| `read()` | Waits for the next packet and returns the full reading struct (see below). Retries for up to 5 s if the meter has not started sending yet. |
| `log(duration)` | Records readings for `duration` seconds and returns a timetable with `Value`, `Scaled`, `Unit` and `Display`. |
| `start()` / `start(fcn)` | Streams readings in the background. `lastReading` is updated on every packet, and `fcn(reading)` is called if given. |
| `stop()` | Stops background streaming. |
| `watch()` / `watch(duration)` | Prints the decoded packet bits each time the display changes (default 30 s). Used to work out which bit drives which LCD symbol. |
| `deInit()` | Stops streaming and disconnects. Returns 1, or 0 if already disconnected. |
| `AnengAN9002.findAddress()` | Static. Returns the address of the first `Bluetooth DMM` found. |
| `AnengAN9002.decode(bytes)` | Static. Decodes one raw 11-byte packet into a reading struct without a connection. |

## The reading struct

Returned by `read()` and `decode()`:

| Field | Meaning |
|---|---|
| `Valid` | Packet had the right length and header |
| `Time` | Timestamp of the packet |
| `Text` | The LCD digits with sign and decimal point, e.g. `'12.34'` |
| `Value` | The number as displayed (12.34 for 12.34 mV) |
| `Unit` | Displayed unit with prefix, e.g. `'mV'` |
| `Scaled` | The value in base units (0.01234 for 12.34 mV) |
| `BaseUnit` | Unit without prefix, e.g. `'V'` |
| `Display` | `Text`, `Unit` and DC or AC as one string, e.g. `'12.34 mV DC'` |
| `Overload` | True when the meter shows OL (`Value` is `Inf`) |
| `Flags` | `DC`, `AC`, `Auto` and `Diode` annunciators |
| `Bytes` | The packet after XOR decoding |

`Flags.Auto` is the small auto-range indicator, not the idle AUTO screen. To detect that screen use `strcmp(r.Text, 'Auto')`.

## What has been verified

Checked against a calibrated Agilent 34405A:

- DC volts, DC amps, resistance
- All ten digits, the `x.xxx` decimal position, the `V`, `A`, `DC` and `Auto` symbols, and the `Auto` idle screen
- The minus sign, with the leads reversed on a bench supply from 0.5 V to 5 V
- The mV range and the `xx.xx` and `xxx.x` decimal positions, against the bench supply's own readback from 50 mV to 500 mV (within 0.5 mV)
- Resistance in Ω, kΩ and MΩ: nominal 10 Ω, 1 kΩ and 2 MΩ resistors read 9.7 Ω, 0.999 kΩ and 1.998 MΩ
- Frequency in Hz, kHz and MHz: noise from floating leads read 237 to 291 Hz, and a function generator set to 2 kHz and 2 MHz read 1.999 kHz and 2.000 MHz
- Capacitance in µF: a nominal 470 µF capacitor read 469.7 µF
- AC volts, from a function generator with a 50 Ω output into the meter's high-impedance input: 1 V peak-to-peak set read `0.723 V AC` (0.707 V expected) and 1 V RMS set read about 2 V
- The µA range, 50 µA to 500 µA through a 10 kΩ resistor (within 1.7 % of V/R, which is inside the resistor tolerance and meter burden)
- The nF prefix, on a `0.000 nF` reading (unit only, no value to compare)
- The overload display: open leads on resistance show `0.L MΩ`, giving `Overload` true and `Value` `Inf`
- The mA range, 0.5 mA to 10 mA through a 1 kΩ resistor (within 1 % of V/R, which is inside the resistor tolerance and meter burden)

Not yet verified on a real meter (taken from published protocol notes): the mF prefix (its bit is assigned by elimination), and temperature.

Not decoded yet: hold, relative, min/max, continuity, low battery and %. `watch()` is the tool for mapping these.

## Notes

- `AnengAN9002` is a handle class, so `b = dmm` is a second reference to the same connection, not a copy.
- The meter auto-powers off after a while. If connecting fails, check that it is on with Bluetooth still enabled.
- Only one connection at a time. Disconnect the phone app before connecting from MATLAB.

## Credits

The packet format was not reverse-engineered here. The XOR key, the segment layout and the unit bit positions come from:

- [ludwich66/Bluetooth-DMM](https://github.com/ludwich66/Bluetooth-DMM) (wiki): XOR key, packet structure, symbol list and a worked example
- [riktw/AN9002_info](https://github.com/riktw/AN9002_info): digit segment order, decimal point, sign and unit bit tests
- [bendtherules decoder gist](https://gist.github.com/bendtherules/4500b2c02ef6bc2f236828ed22af8844): confirmation of the XOR key and mV/V flag behaviour

No code was copied from these projects.

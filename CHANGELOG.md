# Changelog

## v1.4.0 (CLI)

- **Intel Macs are now supported.** On Intel Macs that have the `BCLM` key, `battery maintain 80` sets the Mac's own charge limit to 80% instead of switching charging on and off every minute. It is re-applied after a reboot or wake if needed. `battery maintain stop` and `battery uninstall` put the limit back to 100%.
- `battery charging on/off`, `battery status` and `battery uninstall` work on Intel. Forced discharge isn't possible on Intel, so `battery discharge` and `battery adapter off` explain that and skip it instead of failing.
- `battery status` now also shows whether the battery is really charging, read from `ioreg`, because `pmset` can be minutes behind.
- battery warns you when AlDente is running, since both tools control the same setting and would fight each other.
- The bundled `smc` tool is now one universal binary for Apple Silicon and Intel, with a script (`dist/build-smc.sh`) to rebuild it from source.
- Setup now checks which charging keys your Mac has, instead of assuming Apple Silicon.
- The menu bar app is built as a universal app (Apple Silicon + Intel).
- The passwordless `sudo` rules now also allow reading `BCLM` and setting it to 20-100%.
- Install and update downloads (setup, `battery update`, the menu bar app) now come from this fork, github.com/Salcedoandrew/battery (`main` branch), instead of the original project. Credits to the original battery project by actuallymentor stay in place.

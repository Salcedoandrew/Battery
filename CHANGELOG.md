# Changelog

## v1.5.0 (CLI)

- **Heat protection.** While battery is maintaining a limit, it pauses charging when the battery gets hotter than 35 °C and resumes once it has cooled 2 °C. Change the temperature with `battery heat 40`, or turn it off with `battery heat off`. `battery status` shows the battery temperature and whether charging is paused for heat. On Intel Macs the charge limit is held at the current level while hot, then restored.
- **Top up.** `battery topup` charges once to 100% (for a trip, say) and then goes back to your normal limit by itself. It keeps going if maintenance restarts; `battery topup stop` cancels it.
- **Calibration on Intel.** `battery calibrate` now works on Intel Macs too: it charges to 100%, asks you to unplug and use the Mac down to about 15%, then restores your limit. `battery calibrate stop` cancels a calibration on any Mac, and stopping it now also stops the discharge or charge step it had started.
- The menu bar app has three new items under Advanced settings: pause charging when hot, top up to 100% once, and calibrate.
- Settings are kept in `~/.battery` next to the existing ones (`heat.threshold`, and `topup` while a top-up is running).

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

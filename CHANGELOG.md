# Changelog

## v1.5.2 (CLI)

- **Stop actually stops.** `battery maintain stop` now reliably stops the running limiter on Apple Silicon too — the maintain loops own the pidfile, so a stale PID can't leave a loop running, and the launchd login daemon is stopped as well as disabled. Stopping only signals a process it has verified is battery, waits for it to exit, and reports failure instead of claiming success.
- **SMC failures are no longer reported as success.** A failed SMC read now reports charging as "unknown" instead of "disabled", and a failed SMC write makes the command exit with an error instead of printing success. If the first charging write fails, maintenance stops instead of looping forever on a dead SMC.
- **Verified installs everywhere.** Fresh installs and `battery reinstall` now download `setup.sh`, `smc`, and `battery.sh` from the latest release and verify their SHA-256 checksums before installing — the same check `battery update` already did. The menu bar app's installer is pinned to the release tag instead of `main`, and `setup.sh` defaults to the latest release instead of `main`.
- **Fixed:** `battery maintain 0` is no longer accepted (it disabled charging forever). Valid limits are now 10–100.

## v1.5.1 (CLI)

- **Safer updates.** `battery update` no longer runs code straight from the `main` branch. It downloads `battery.sh` from the latest GitHub release and checks its SHA-256 checksum before installing, and refuses to install if the checksum doesn't match. `battery reinstall` now reinstalls from the latest release tag instead of `main`. Publish the checksum with every release: `./scripts/publish-cli-assets.sh v1.5.1`.
- **Check for updates.** `battery check-update` asks GitHub for the latest release and tells you if a newer version is out — it downloads nothing and changes nothing. The menu bar app's "Check for updates" item now runs this check inside the app and offers to install the update if there is one, instead of opening the releases page.
- **Fixed:** the log no longer gets wiped when it grows past 5 MB (it now keeps the last 100 lines properly).
- **Fixed:** a mistyped `battery maintain` setting (like `battery maintain 999`) no longer kills the running limiter before failing.

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

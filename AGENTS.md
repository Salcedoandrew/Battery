This repository contains software that limits the battery charging level of Apple Silicon and Intel (BCLM) macbooks.

## Project structure

- `./battery.sh` is the main CLI binary used under the hood
- `./setup.sh` is the setup script for the binary
- `./update.sh` is the script used to update the binary
- `./app/` contains an electron codebase for a GUI that wraps around the CLI
- `./dist` contains precompiled binaries that are shipped with the CLI

## Development flow

- any changes made to `battery.sh` must also increment the version number at the top of `battery.sh` as this is what the update command relies on
- any changes to `smc` commands must update the `visudoconfig` variable in `battery.sh` as this updates the visudo entry on the client device to make sure smc may run commands without sudo
- the GUI keeps no list of its own smc commands (there is no `smc_commands` variable in `app/modules/battery.js`): it shells out to the CLI, so an smc-command change only needs the `visudoconfig` update above, plus the `update_silent is_enabled` check the GUI runs at startup

## Mantatory checks

Before finishing any task, make sure that you:

- do a sanity check for bugs
- check that comments still reflect the changed code

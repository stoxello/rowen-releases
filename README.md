# Rowen releases

Downloadable builds of [Rowen](https://github.com/stoxello/rowen) are published on the [Releases page](https://github.com/stoxello/rowen-releases/releases). Each release includes a Windows desktop GUI, a Windows console build, an Ubuntu x64 console build, and `SHA256SUMS.txt`. These are development previews while desktop and console feature parity is being built.

## Windows desktop GUI

1. Open the [latest published release](https://github.com/stoxello/rowen-releases/releases) and download `Rowen-Desktop-win-x64-<version>.zip`.
2. Extract **all** files into a folder you own. Run `Rowen.App.exe` from that folder. The ZIP is a self-contained build, so a separate .NET runtime is not needed.
3. The **Active workspace** indicator shows `Local · This PC`. The main menus use the Windows machine's data and services. Start with **Settings**, then use **Market Data**, **AI / Models**, **Training**, **Backtests**, or **Paper Trading** as needed. **Live Trading** involves real money; review its readiness and risk controls before enabling it.

The **Remote Preview** screen can connect to an Ubuntu Console instance to view status and models and run a historical data download. It is a development preview: connecting there does **not** switch the other desktop menus to the remote machine. Full Local/Remote menu switching is still in development.

## Ubuntu console: one-command install

On an Ubuntu x64 machine, run:

```bash
curl -fsSL https://raw.githubusercontent.com/stoxello/rowen-releases/main/install-console.sh | bash
```

The installer needs `curl`, `python3`, `sha256sum`, and a working systemd user session. It selects the newest published release containing an Ubuntu x64 console ZIP, checks its SHA-256 hash against that release's `SHA256SUMS.txt`, and installs the self-contained app to `~/.local/share/rowen/versions/<version>`. It links `~/.local/bin/rowen` to the installed version, creates a default configuration and control token when needed, and enables and starts `rowen.service` for your user. Run the installer as your normal login user, without `sudo`. It does not need a separate .NET runtime. If `rowen` is not yet on your `PATH`, use `~/.local/bin/rowen` directly or start a new login session.

After installation, check the instance and service:

```bash
~/.local/bin/rowen doctor
systemctl --user status rowen.service
```

The service runs while your user manager is active. For startup at boot and operation after logout, run `sudo loginctl enable-linger "$USER"` if the installer prints that step. You can change the default configuration with `~/.local/bin/rowen setup`; restart the service afterward with `systemctl --user restart rowen.service`.

Running `rowen` without arguments opens an interactive help menu. Useful commands include `rowen help`, `rowen status`, `rowen models list`, `rowen data summary BTC-USD Minute5`, and `rowen data sync BTC-USD Minute5 2026-01-01T00:00:00Z 2026-01-02T00:00:00Z`. `rowen help data` explains the data commands. Console also supports training, backtesting, paper sessions, and read-only Robinhood commands. Run `rowen help paper` for paper session controls.

### Connect the Windows GUI to the Ubuntu Console preview

The installer creates a control token on first install. Run `~/.local/bin/rowen remote token` if you need to see it again. The control server is already running through `rowen.service`.

The server listens on Ubuntu's `127.0.0.1:5188`. On Windows, open a separate terminal and forward the port over SSH, replacing the login and host:

```powershell
ssh -N -L 5188:127.0.0.1:5188 user@ubuntu-host
```

In the desktop GUI, open **Remote Preview**, keep `http://127.0.0.1:5188` as the endpoint, enter the Ubuntu control token, and select **Connect**. Closing the desktop app or SSH tunnel does not cancel a historical download already submitted to the server. Reconnect to inspect its job status.

## Windows console

Download `Rowen-Console-win-x64-<version>.zip` from the [Releases page](https://github.com/stoxello/rowen-releases/releases), extract all files, and run `Rowen.Console.exe` in PowerShell. Run `Rowen.Console.exe help` to see the commands or `Rowen.Console.exe setup` to configure it. This is the same Console entry point packaged for Windows.

## Updating and verification

Run the Ubuntu one-command installer again to install the newest published version, move the `~/.local/bin/rowen` link to it, and restart the service. Existing configuration and data live outside the application folder and remain in place. For manual downloads, compare the ZIP's SHA-256 hash with `SHA256SUMS.txt` in the same release before extracting it.

Source code, build instructions, and current feature status are in [stoxello/rowen](https://github.com/stoxello/rowen).

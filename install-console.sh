#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'Rowen Console installer requires Linux x86_64 (Ubuntu x64).' >&2
  exit 1
fi
for command_name in curl python3 sha256sum systemctl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo 'Cannot reach the systemd user manager. Run this installer as your login user, without sudo.' >&2
  exit 1
fi
versions_dir="$HOME/.local/share/rowen/versions"
bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"
unit_name='rowen.service'
mkdir -p "$versions_dir" "$bin_dir" "$unit_dir"
work_dir="$(mktemp -d)"
stage_dir=''
cleanup() {
  if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then rm -rf -- "$stage_dir"; fi
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then rm -rf -- "$work_dir"; fi
}
trap cleanup EXIT

releases_json="$work_dir/releases.json"
curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
  'https://api.github.com/repos/stoxello/rowen-releases/releases?per_page=100' \
  -o "$releases_json"

mapfile -t release_info < <(python3 - "$releases_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    releases = json.load(stream)
for release in releases:
    if release.get("draft"):
        continue
    tag = release.get("tag_name", "")
    asset_name = f"Rowen-Console-linux-x64-{tag}.zip"
    assets = {asset["name"]: asset["browser_download_url"] for asset in release.get("assets", [])}
    if asset_name in assets and "SHA256SUMS.txt" in assets:
        print(tag)
        print(assets[asset_name])
        print(assets["SHA256SUMS.txt"])
        break
PY
)

if [[ "${#release_info[@]}" -ne 3 ]]; then
  echo 'No published Rowen release with an Ubuntu x64 Console ZIP was found.' >&2
  exit 1
fi
tag="${release_info[0]}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  echo "Unexpected release tag: $tag" >&2
  exit 1
fi

zip_name="Rowen-Console-linux-x64-$tag.zip"
zip_path="$work_dir/$zip_name"
curl -fsSL --retry 3 "${release_info[1]}" -o "$zip_path"
curl -fsSL --retry 3 "${release_info[2]}" -o "$work_dir/SHA256SUMS.txt"
expected_hash="$(awk -v name="$zip_name" '$2 == name { print $1 }' "$work_dir/SHA256SUMS.txt")"
actual_hash="$(sha256sum "$zip_path")"
actual_hash="${actual_hash%% *}"
if [[ ! "$expected_hash" =~ ^[0-9a-fA-F]{64}$ || "${expected_hash,,}" != "$actual_hash" ]]; then
  echo "SHA-256 verification failed for $zip_name" >&2
  exit 1
fi

install_dir="$versions_dir/$tag"
if [[ ! -d "$install_dir" ]]; then
  stage_dir="$(mktemp -d "$versions_dir/.install.XXXXXXXX")"
  python3 - "$zip_path" "$stage_dir" <<'PY'
import pathlib
import sys
import zipfile

destination = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(sys.argv[1]) as archive:
    for item in archive.infolist():
        path = pathlib.PurePosixPath(item.filename)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"Unsafe archive entry: {item.filename}")
    archive.extractall(destination)
PY
  if [[ ! -f "$stage_dir/Rowen.Console" ]]; then
    echo 'Downloaded archive does not contain Rowen.Console.' >&2
    exit 1
  fi
  chmod +x "$stage_dir/Rowen.Console"
  mv -- "$stage_dir" "$install_dir"
  stage_dir=''
fi

if [[ ! -x "$install_dir/Rowen.Console" ]]; then
  echo "Installed version is missing its executable: $install_dir" >&2
  exit 1
fi
if [[ -e "$bin_dir/rowen" && ! -L "$bin_dir/rowen" ]]; then
  echo "$bin_dir/rowen already exists and is not a symlink; move it before installing." >&2
  exit 1
fi
if systemctl --user is-active --quiet "$unit_name"; then
  systemctl --user stop "$unit_name"
fi
ln -sfnT -- "$install_dir/Rowen.Console" "$bin_dir/rowen"
cat > "$unit_dir/$unit_name" <<'UNIT'
[Unit]
Description=Rowen Console engine and control API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/.local/share/rowen
ExecStart=%h/.local/bin/rowen serve
Restart=on-failure
RestartSec=5s
UMask=0077

[Install]
WantedBy=default.target
UNIT

config_file="${XDG_CONFIG_HOME:-$HOME/.config}/rowen/appsettings.json"
if [[ ! -f "$config_file" ]]; then
  echo 'Creating default Rowen configuration and control token.'
  "$bin_dir/rowen" remote init
fi

systemctl --user daemon-reload
systemctl --user enable --now "$unit_name"
if ! systemctl --user is-active --quiet "$unit_name"; then
  systemctl --user status "$unit_name" --no-pager || true
  echo 'Rowen did not start. Inspect: journalctl --user -u rowen.service -n 50' >&2
  exit 1
fi
echo "Installed Rowen Console $tag at $install_dir"
echo 'Rowen is running as a systemd user service.'
echo 'Check it with: systemctl --user status rowen.service'
if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" != yes ]]; then
  linger_enabled=false
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n loginctl enable-linger "$(id -un)" 2>/dev/null; then
      linger_enabled=true
    elif [[ -t 2 ]] && sudo loginctl enable-linger "$(id -un)"; then
      linger_enabled=true
    fi
  fi
  if [[ "$linger_enabled" != true ]]; then
    echo "For boot startup and operation after logout, run: sudo loginctl enable-linger $(id -un)"
  fi
fi

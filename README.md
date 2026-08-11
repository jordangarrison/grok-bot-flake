# grok-bot-flake

Nix flake for [Grok Bot](https://x.ai/news/introducing-grok-bot), xAI's desktop
agent, on Linux. It repackages the official amd64 `.deb` — there is no source
build.

> [!NOTE]
> Grok Bot is proprietary (`meta.license = unfree`). This flake is not
> affiliated with xAI or Cursor.

## Quick start

Run it once, without installing:

```sh
nix run github:jordangarrison/grok-bot-flake
```

This works, but `sand://` login-redirect links will not route back to the app
until the package is properly installed — see
[Getting sand:// links to work](#getting-sand-links-to-work).

## Add it to your Nix config

### Flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    grok-bot = {
      url = "github:jordangarrison/grok-bot-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

### NixOS

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.grok-bot.packages.${pkgs.system}.default
  ];
}
```

### Home Manager

```nix
{ inputs, pkgs, ... }:
{
  home.packages = [
    inputs.grok-bot.packages.${pkgs.system}.default
  ];
}
```

### Overlay (if you prefer `pkgs.grok-bot`)

```nix
nixpkgs.overlays = [ inputs.grok-bot.overlays.default ];
environment.systemPackages = [ pkgs.grok-bot ];
```

The flake's own `packages` output already allows unfree for you. The overlay
deliberately does not — it uses your nixpkgs config, so you need `allowUnfree`
(or an `allowUnfreePredicate` matching `grok-bot`) when consuming it that way.

### Imperative install

```sh
nix profile install github:jordangarrison/grok-bot-flake
```

## What you get

- `grok-bot` — the app, wrapped for NixOS (patchelf'd, GApps-wrapped,
  Wayland-aware).
- `sand` — an alias for the same binary. Upstream names the executable `sand`
  and registers the `sand://` URL scheme, which the login flow uses.
- `share/applications/grok-bot.desktop` + icon, so launchers and URL-scheme
  routing can find the app.

Wayland is opt-in through the usual NixOS variable: with `NIXOS_OZONE_WL=1`
set (and a Wayland session), the wrapper adds `--ozone-platform-hint=auto` and
Wayland window decorations. Otherwise it runs under XWayland/X11.

## Getting sand:// links to work

Login redirects open `sand://...` URLs. For your desktop environment to route
those to Grok Bot, two things must hold:

1. **`grok-bot.desktop` must be on `XDG_DATA_DIRS`** — true automatically once
   the package is installed via NixOS, Home Manager, or `nix profile install`.
   A bare `nix run` does not do this.
2. **The scheme must map to the app.** The app registers itself on first launch
   (the wrapper sets `CHROME_DESKTOP=grok-bot.desktop` so Electron registers
   the right desktop id). To set it manually:

   ```sh
   xdg-mime default grok-bot.desktop x-scheme-handler/sand
   ```

Verify with:

```sh
xdg-mime query default x-scheme-handler/sand   # → grok-bot.desktop
```

Empty output means the desktop file isn't visible (see 1). The desktop *id*
stays `grok-bot.desktop` across rebuilds even though the store path in `Exec=`
changes, so the association survives upgrades.

## Packaging notes

Upstream ships its own Electron 42 build, and the bundled native modules
(`better-sqlite3`, `tree-sitter`, and others) are compiled against it. This
flake keeps that Electron instead of swapping in `pkgs.electron_42` — no ABI
risk, and the result matches what upstream tests.

The build unpacks the `.deb`, runs `autoPatchelfHook` over the binaries and
`.node` modules, and wraps the launcher with `wrapGAppsHook3`.

Differences from the `.deb`:

- **`chrome-sandbox` is removed.** It only works setuid root, which the Nix
  store cannot express. Chromium falls back to the user-namespace sandbox,
  which NixOS enables by default. If your kernel disables unprivileged user
  namespaces, the app will not start — re-enable them rather than running
  with `--no-sandbox`.
- **`--no-sandbox` is added.** Upstream's custom Electron build crash-loops
  every `sandbox: true` renderer — notably the `<webview>` that shows your
  agent's box screen — with `FATAL:platform_shared_memory_region_posix.cc`
  (`/dev/shm ... No such process`). Traced with strace: the renderer is forked
  from the sandboxed zygote (chroot'd into a dead `/proc/<tid>/fdinfo`, which
  is where the odd `ESRCH` comes from) and then tries to create `/dev/shm`
  shared memory *directly*. Stock Chromium brokers that allocation through the
  browser process; upstream's build never installs the broker hooks for
  webview renderers, so the crash is environment-independent — the same
  signature is reported for `.deb`-class Electron apps on stock Ubuntu
  ([electron#30758](https://github.com/electron/electron/issues/30758),
  [open-webui/desktop#157](https://github.com/open-webui/desktop/issues/157)).
  A stock nixpkgs `electron_42` runs the identical sandboxed renderer fine.

  The flag costs nothing that works today: upstream already launches its main
  renderer with `--no-sandbox --no-zygote`, its GPU process with
  `--no-sandbox`, and every utility process with
  `--service-sandbox-type=none`. The webview was the only process that got a
  real sandbox, and it only ever crashed. The flag will be removed when
  upstream fixes their sandboxed-renderer shared-memory path.
- **The AppArmor profile is not installed.** It is Ubuntu-specific and refers
  to `/opt` paths that do not exist here.

## Updating

```sh
./update.sh
```

Reads the current stable version from upstream's update feed and rewrites
`version`, `buildId`, and `hash` in `package.nix`.

One wrinkle: upstream's Linux update feed is empty — `linux-x64` answers HTTP
204 for every version, and the in-app updater has no Linux branch at all (it
falls through to `darwin-arm64`). The build id in the download URL is shared
across platforms, so the script reads the darwin-arm64 feed and rebuilds the
Linux `.deb` URL from it. This also means **in-app self-update does not work
on Linux** — re-run `./update.sh` and rebuild instead.

To pin an exact build, pass its URL:

```sh
./update.sh https://downloads.cursor.com/sand/stable/<buildId>/linux/x64/Grok_Bot_<version>.deb
```

## Provenance

The `.deb` is served from `downloads.cursor.com`, its control file lists
`SpaceXAI <hi@cursor.com>` as vendor with `Homepage: https://cursor.com`, and
the package name is `sand`. The app is built on Cursor's release
infrastructure. That is expected, not a mis-download.

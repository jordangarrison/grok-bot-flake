# grok-bot-flake

Nix flake for [Grok Bot](https://x.ai/news/introducing-grok-bot), xAI's desktop
agent. It repackages the official amd64 `.deb` — there is no source build.

## Use it

Run it once, without installing:

```sh
nix run github:jordangarrison/grok-bot-flake
```

Add it to a NixOS or Home Manager config:

```nix
{
  inputs.grok-bot.url = "github:jordangarrison/grok-bot-flake";

  # NixOS
  environment.systemPackages = [ inputs.grok-bot.packages.x86_64-linux.default ];

  # or Home Manager
  home.packages = [ inputs.grok-bot.packages.x86_64-linux.default ];
}
```

There is also an overlay, if you prefer `pkgs.grok-bot`:

```nix
nixpkgs.overlays = [ inputs.grok-bot.overlays.default ];
```

The overlay uses your own nixpkgs, so it needs `allowUnfree` set for
`grok-bot`. The flake's own `packages` and `apps` outputs already allow it.

The package installs `grok-bot` plus a `sand` alias — upstream names the binary
`sand` and registers the `sand://` URL scheme, which the login redirect uses.

## How it is built

Upstream ships its own Electron 42 build, and the bundled native modules
(`better-sqlite3`, `tree-sitter`, and others) are compiled against it. So this
flake keeps that Electron instead of swapping in `pkgs.electron_42` — no ABI
risk, and the result matches what upstream tests.

The build unpacks the `.deb`, runs `autoPatchelfHook` over the binaries and the
`.node` modules, and wraps the launcher with `wrapGAppsHook3`.

Two things differ from the `.deb`:

- `chrome-sandbox` is removed. It only works when setuid root, which the Nix
  store cannot do. Chromium falls back to the user-namespace sandbox, which
  NixOS enables by default. If yours is off
  (`security.unprivileged_userns_clone` / `user.max_user_namespaces = 0`), the
  app will not start — turn user namespaces back on rather than passing
  `--no-sandbox`.
- The AppArmor profile is not installed. It is Ubuntu-specific and refers to
  `/opt` paths that do not exist here.

Wayland is opt-in through the usual NixOS variable — set `NIXOS_OZONE_WL=1` and
the wrapper adds `--ozone-platform-hint=auto`.

## Updating

```sh
./update.sh
```

The script reads the current stable version from upstream's update feed and
rewrites `version`, `buildId`, and `hash` in `package.nix`.

One wrinkle: upstream's Linux update feed is empty — `linux-x64` answers HTTP
204 for every version, and the in-app updater has no Linux branch at all
(`resolveUpdatePlatform` falls through to `darwin-arm64`). The build id in the
download URL is shared across platforms, so the script reads the darwin-arm64
feed and rebuilds the Linux `.deb` URL from it.

To pin an exact build instead, pass its URL:

```sh
./update.sh https://downloads.cursor.com/sand/stable/<buildId>/linux/x64/Grok_Bot_<version>.deb
```

## Note on provenance

The binary is served from `downloads.cursor.com` and the `.deb` control file
lists `SpaceXAI <hi@cursor.com>` as vendor, with `Homepage: https://cursor.com`.
The app is built on Cursor's release infrastructure, and the package name is
`sand`. That is expected, not a mis-download.

Grok Bot is proprietary. `meta.license` is `unfree`.

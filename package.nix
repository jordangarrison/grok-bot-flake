{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeShellWrapper,
  wrapGAppsHook3,

  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libGL,
  libglvnd,
  libnotify,
  libpulseaudio,
  libsecret,
  libuuid,
  libx11,
  libxcb,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxkbcommon,
  libxrandr,
  libxrender,
  libxscrnsaver,
  libxshmfence,
  libxtst,
  nspr,
  nss,
  pango,
  systemd,
  vulkan-loader,
  wayland,
  xdg-utils,
}:

let
  # The download URL embeds an upstream product namespace and build id
  # alongside the version. All three come from the stable channel manifest --
  # see ./update.sh.
  downloadBase = "https://downloads.cursor.com/grokbot/stable";
  buildId = "ca2c2b6f79b6130a4822d8189711b0f79f9d4661";

  # Shared libraries the bundled Chromium dlopen()s at runtime rather than
  # linking against, so autoPatchelfHook cannot discover them on its own.
  runtimeLibs = [
    libglvnd
    libGL
    libgbm
    libdrm
    vulkan-loader
    wayland
    libxkbcommon
    libpulseaudio
    libsecret
    libnotify
    (lib.getLib systemd)
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "grok-bot";
  version = "0.20.0";

  src = fetchurl {
    url = "${downloadBase}/${buildId}/linux/x64/Grok_Bot_${finalAttrs.version}.deb";
    hash = "sha256-Z6brYWSrIzpcXU1QZl762iy6rp8i763oXpNKZf37sg0=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeShellWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libuuid
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    libx11
    libxcb
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxscrnsaver
    libxshmfence
    libxtst
  ]
  ++ runtimeLibs;

  # Keep the dlopen()ed libraries reachable via RPATH.
  runtimeDependencies = runtimeLibs;

  # Prebuilt Electron -- stripping buys nothing and takes minutes.
  dontStrip = true;

  # We wrap by hand below so the GApps args land on our own wrapper.
  dontWrapGApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/grok-bot"
    cp -r "opt/Grok Bot/." "$out/share/grok-bot/"

    # chrome-sandbox needs to be setuid root, which the Nix store cannot do.
    # Chromium falls back to the user-namespace sandbox, which NixOS enables.
    rm -f "$out/share/grok-bot/chrome-sandbox"

    # Upstream renamed the Debian package, binary, desktop file, and icon from
    # `sand` to `grok-bot` in 0.19.0. Accept either layout so routine updates
    # across that transition (and old pinned builds) keep working.
    if [ -f usr/share/icons/hicolor/1024x1024/apps/grok-bot.png ]; then
      icon=usr/share/icons/hicolor/1024x1024/apps/grok-bot.png
    else
      icon=usr/share/icons/hicolor/1024x1024/apps/sand.png
    fi
    install -Dm644 "$icon" \
      "$out/share/icons/hicolor/1024x1024/apps/grok-bot.png"

    if [ -f usr/share/applications/grok-bot.desktop ]; then
      desktop=usr/share/applications/grok-bot.desktop
      desktopExec='"/opt/Grok Bot/grok-bot"'
    else
      desktop=usr/share/applications/sand.desktop
      desktopExec='"/opt/Grok Bot/sand"'
    fi
    install -Dm644 "$desktop" "$out/share/applications/grok-bot.desktop"
    substituteInPlace "$out/share/applications/grok-bot.desktop" \
      --replace-fail "$desktopExec" "$out/bin/grok-bot"
    sed -i 's/^Icon=.*/Icon=grok-bot/' \
      "$out/share/applications/grok-bot.desktop"

    runHook postInstall
  '';

  preFixup = ''
    # makeShellWrapper, not makeWrapper: wrapGAppsHook3 pulls in
    # makeBinaryWrapper, whose wrappers pass argv through literally. The
    # conditional ozone flags below need real shell parameter expansion, and a
    # binary wrapper would hand the app an unexpanded "''${NIXOS_OZONE_WL:+..."
    # string as a positional argument -- which Electron reads as a deep link.
    #
    # CHROME_DESKTOP is how Electron's setAsDefaultProtocolClient() decides
    # which .desktop id to hand xdg-settings when the app registers sand://.
    # Unset, it guesses "electron.desktop" and the registration points at
    # nothing, so sand:// links never reach the app.
    # --no-sandbox: upstream's custom Electron build crash-loops every
    # `sandbox: true` renderer -- the <webview> that shows the agent's box
    # screen -- with FATAL:platform_shared_memory_region_posix.cc. Traced with
    # strace: the renderer is forked from the sandboxed zygote (chroot'd into
    # a dead /proc/<tid>/fdinfo, hence the odd ESRCH) and then tries to create
    # /dev/shm shared memory directly. Stock Chromium brokers that through the
    # browser process; their build never installs the broker hooks for webview
    # renderers, so the crash reproduces on stock Ubuntu with the .deb too
    # (same signature as electron#30758, open-webui/desktop#157). A stock
    # nixpkgs electron_42 runs the identical sandboxed renderer fine, so this
    # is upstream's bug, not this package's.
    #
    # The flag costs nothing that works today: upstream already launches the
    # main renderer with --no-sandbox --no-zygote, the GPU process with
    # --no-sandbox, and every utility with --service-sandbox-type=none. The
    # webview was the only sandboxed process, and it only ever crashed.
    # Remove the flag when upstream fixes their sandboxed-renderer shm path.
    if [ -x "$out/share/grok-bot/grok-bot" ]; then
      upstreamExecutable="$out/share/grok-bot/grok-bot"
    else
      upstreamExecutable="$out/share/grok-bot/sand"
    fi

    makeShellWrapper "$upstreamExecutable" "$out/bin/grok-bot" \
      "''${gappsWrapperArgs[@]}" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --set-default CHROME_DESKTOP grok-bot.desktop \
      --add-flags "--no-sandbox" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"

    # Keep the historical binary name used by older releases and sand:// URLs.
    ln -s "$out/bin/grok-bot" "$out/bin/sand"
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Grok Bot desktop agent";
    homepage = "https://x.ai/news/introducing-grok-bot";
    downloadPage = "https://cursor.com";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "grok-bot";
  };
})

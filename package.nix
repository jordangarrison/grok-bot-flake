{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
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
  # The download URL embeds an upstream build id alongside the version.
  # Both come from the "stable" channel manifest -- see ./update.sh.
  buildId = "076e9d4bf42abbfa576702aea18ddbc49d9d3ab5";

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
  version = "0.16.0";

  src = fetchurl {
    url = "https://downloads.cursor.com/sand/stable/${buildId}/linux/x64/Grok_Bot_${finalAttrs.version}.deb";
    hash = "sha256-mdizlmQZQbpLiJp5HpMGc3s5jAw5NPY6lUVDCRAZK8w=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
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

    install -Dm644 usr/share/icons/hicolor/1024x1024/apps/sand.png \
      "$out/share/icons/hicolor/1024x1024/apps/grok-bot.png"

    install -Dm644 usr/share/applications/sand.desktop \
      "$out/share/applications/grok-bot.desktop"
    substituteInPlace "$out/share/applications/grok-bot.desktop" \
      --replace-fail '"/opt/Grok Bot/sand"' "$out/bin/grok-bot" \
      --replace-fail 'Icon=sand' 'Icon=grok-bot'

    runHook postInstall
  '';

  preFixup = ''
    makeWrapper "$out/share/grok-bot/sand" "$out/bin/grok-bot" \
      "''${gappsWrapperArgs[@]}" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"

    # Upstream calls the binary "sand" and registers the sand:// URL scheme.
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

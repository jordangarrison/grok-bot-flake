{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "grok-bot";
  version = "1.2.3";

  src = fetchurl {
    url = "https://downloads.cursor.com/grokbot/stable/darwin-arm64/${finalAttrs.version}/Grok_Bot_${finalAttrs.version}.zip";
    hash = "sha256-sYedtXy1RVevF5qwxEY28kdA9C4JNEFQ2E7YaE/cbgg=";
  };

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";

  # Preserve upstream's Developer ID signature and stapled notarization ticket.
  # macOS privacy grants follow that identity: never patch, strip, or re-sign.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications" "$out/bin"
    cp -R "Grok Bot.app" "$out/Applications/"
    ln -s "$out/Applications/Grok Bot.app/Contents/MacOS/Grok Bot" "$out/bin/grok-bot"
    ln -s "$out/bin/grok-bot" "$out/bin/sand"
    runHook postInstall
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Grok Bot desktop agent";
    homepage = "https://x.ai/news/introducing-grok-bot";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "aarch64-darwin" ];
    mainProgram = "grok-bot";
  };
})

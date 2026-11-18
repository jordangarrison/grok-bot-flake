{
  description = "Grok Bot desktop agent, packaged for Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      packageFor = system: if system == "aarch64-darwin" then ./package-darwin.nix else ./package.nix;

      # Grok Bot is proprietary, and this flake exists only to package it, so
      # allow unfree here rather than making every consumer opt in. The overlay
      # below deliberately does not, so it respects the caller's own config.
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          }
        );
    in
    {
      packages = forAllSystems (
        { pkgs, system }:
        rec {
          grok-bot = pkgs.callPackage (packageFor system) { };
          default = grok-bot;
        }
      );

      overlays.default = final: _prev: {
        grok-bot = final.callPackage (packageFor final.stdenv.hostPlatform.system) { };
      };

      apps = forAllSystems (
        { system, ... }:
        let
          grok-bot = {
            type = "app";
            program = "${self.packages.${system}.grok-bot}/bin/grok-bot";
            meta = self.packages.${system}.grok-bot.meta;
          };
        in
        {
          inherit grok-bot;
          default = grok-bot;
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt);
    };
}

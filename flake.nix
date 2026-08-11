{
  description = "Grok Bot desktop agent, packaged for Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Upstream ships an amd64 .deb only.
      systems = [ "x86_64-linux" ];

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
        { pkgs, ... }:
        rec {
          grok-bot = pkgs.callPackage ./package.nix { };
          default = grok-bot;
        }
      );

      overlays.default = final: _prev: {
        grok-bot = final.callPackage ./package.nix { };
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

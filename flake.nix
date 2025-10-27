{
  description = "One-shot NixOS installer";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.writeShellApplication {
            name = "install-nixos";
            runtimeInputs = with pkgs; [
              bash
              coreutils
              util-linux         # lsblk, findmnt, blockdev, wipefs
              gnugrep
              gawk
              findutils
              gnused
              parted
              dosfstools         # mkfs.vfat
              e2fsprogs          # mkfs.ext4
              rsync
              gptfdisk           # sgdisk (optional)
              nixos-install-tools # nixos-install, nixos-generate-config, nixos-enter
            ];
            # Pull the script contents from the separate file:
            text = builtins.readFile ./install-nixos.sh;
          };
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/install-nixos";
        };
      });
    };
}

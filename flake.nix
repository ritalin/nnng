{
    description = "nng dev env";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs";
        flake-utils.url = "github:numtide/flake-utils";
    };

    outputs = { self, nixpkgs, flake-utils }: flake-utils.lib.eachDefaultSystem(
        system:
        let
            pkgs = nixpkgs.legacyPackages.${system};
        in {
            devShells.default = pkgs.mkShell {
              buildInputs = [
                pkgs.zsh
                pkgs.starship
                pkgs.bintools
                pkgs.nng
              ];
              shellHook = ''
                export NNG_PREFIX=${pkgs.nng}
                eval "$(starship init bash)"
              '';
            };
        }
    );
}

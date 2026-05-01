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
                pkgs.nng
                pkgs.bintools
              ];
              shellHook = ''
                export PS1="nix-dev> "
                export NNG_PREFIX=${pkgs.nng}
              '';
            };
        }
    );
}

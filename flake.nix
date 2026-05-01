{
    description = "nng dev env";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs";
    };

    outputs = { self, nixpkgs }:
        let
            system = builtins.currentSystem;
            pkgs = nixpkgs.legacyPackages.${system};
        in {
            devShells.${system}.default = pkgs.mkShell {
                buildInputs = [
                    pkgs.nng
                ];
            };
        };
}

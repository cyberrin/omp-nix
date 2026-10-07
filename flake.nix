{
  description = "Declarative Oh My Pi (OMP) plugin and marketplace manager for Home Manager";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    claude-plugins-official = {
      url = "github:anthropics/claude-plugins-official";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      claude-plugins-official,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      # Home Manager modules (supporting both standard and legacy flake output schemas)
      homeManagerModules.omp = import ./modules/omp.nix {
        defaultOfficialMarketplace = claude-plugins-official;
      };
      homeManagerModules.default = self.homeManagerModules.omp;
      homeModules.omp = self.homeManagerModules.omp;
      homeModules.default = self.homeManagerModules.omp;
      lib = import ./lib/plugins.nix;

      # Per-system outputs
      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Standalone test evaluation
          testEval = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              ./tests/test-config.nix
            ];
          };
        in
        {
          # Synthesizes and extracts the generated JSON files for inspection
          test-json = pkgs.runCommand "omp-test-json-output" { } ''
            mkdir -p $out
            cp ${testEval.config.xdg.dataFile."omp/plugins/installed_plugins.json".source} $out/installed_plugins.json
            cp ${testEval.config.xdg.dataFile."omp/marketplaces.json".source} $out/marketplaces.json
            cp ${testEval.config.xdg.dataFile."omp/plugins/omp-plugins.lock.json".source} $out/omp-plugins.lock.json
          '';

          default = self.packages.${system}.test-json;
        }
      );

      # Checks to verify evaluation and JSON correctness
      checks = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          test-json = pkgs.runCommand "omp-check-test-json" {
            nativeBuildInputs = [ pkgs.jq ];
          } ''
            mkdir -p $out
            # Validate JSON syntax
            jq . ${self.packages.${system}.test-json}/installed_plugins.json > $out/installed.json
            jq . ${self.packages.${system}.test-json}/marketplaces.json > $out/marketplaces.json
            jq . ${self.packages.${system}.test-json}/omp-plugins.lock.json > $out/lock.json

            # Verify contents
            jq -e '.plugins["clangd-lsp@claude-plugins-official"]' $out/installed.json > /dev/null
            jq -e '.plugins["mock-plugin@test-marketplace"]' $out/installed.json > /dev/null
            jq -e '.plugins["mock-extension@test-marketplace"]' $out/installed.json > /dev/null
            jq -e '.plugins["mock-standalone@nix-declarative"]' $out/installed.json > /dev/null
            jq -e '.marketplaces[] | select(.name == "test-marketplace")' $out/marketplaces.json > /dev/null
            jq -e '.marketplaces[] | select(.name == "claude-plugins-official")' $out/marketplaces.json > /dev/null

            echo "All checks passed!" > $out/success
          '';
        }
      );

      # Developer Shell
      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              git
              jq
              nixd
            ];

            shellHook = ''
              echo "OMP Declarative Plugin Manager Flake DevShell"
              echo "Run 'nix build .#test-json' to build and preview the generated JSON output."
              echo "Run 'nix flake check' to run tests."
            '';
          };
        }
      );
    };
}

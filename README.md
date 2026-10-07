# omp-nix

Declarative plugin and marketplace manager for [Oh My Pi (OMP)](https://github.com/can1357/oh-my-pi) via [Home Manager](https://github.com/nix-community/home-manager).

Provides declarative control over OMP plugins without requiring manual commit SHAs, versions, or imperative `/marketplace install` commands.

## Architecture

OMP discovers marketplace plugins via internal JSON registries:
- `$XDG_DATA_HOME/omp/marketplaces.json` (Catalog registry, schema v1)
- `$XDG_DATA_HOME/omp/plugins/installed_plugins.json` (Installed plugins registry, schema v2)
- `$XDG_DATA_HOME/omp/plugins/omp-plugins.lock.json` and `node_modules/` (Runtime surfaces for TypeScript/Bun extensions)
- `~/.omp/agent/config.yml` (`marketplace.autoUpdate: "off"` to prevent background mutations over immutable Nix store paths)

This flake synthesizes these registries directly from your declared Nix configuration into the Nix store and links them into place.

## Features

- **Zero-Version Friction**: Specify `"marketplace:clangd-lsp"` or `"github:owner/repo"` without manually looking up commit hashes or version strings.
- **Official Marketplace Included**: Pinned upstream catalog (`anthropics/claude-plugins-official`) is included as a flake input, providing pure, deterministic evaluation out of the box.
- **Universal Repo Support**: Auto-detects `.omp-plugin/marketplace.json`, `.claude-plugin/marketplace.json`, or root `marketplace.json`. Standalone plugin repositories without catalogs are automatically registered as ad-hoc single-plugin marketplaces.
- **Works Standalone or as an Extension**: Seamlessly extends the official `oh-my-pi` Home Manager module (`inputs.omp.homeManagerModules.default`) or functions standalone.
- **Extension Module Support**: Synthesizes `node_modules` symlinks and `omp-plugins.lock.json` for plugins declaring `package.json#omp.extensions`.

---

## Quick Start

### 1. Add flake input

In your dotfiles or NixOS `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Official OMP flake (optional, if you want OMP packaged via Nix)
    omp = {
      url = "github:can1357/oh-my-pi";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # This flake
    omp-plugins = {
      url = "github:cyberrin/omp-plugins-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # This flake
    omp-plugins = {
      url = "github:cyberrin/omp-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
      pkgs = nixpkgs.legacyPackages."x86_64-linux";
      modules = [
        omp.homeManagerModules.default          # Official OMP module
        omp-plugins.homeManagerModules.default  # This declarative plugin extension
        ./home.nix
      ];
    };
  };
}
```

### 2. Configure plugins in `home.nix`

```nix
{ pkgs, ... }:
{
  programs.omp = {
    enable = true;

    # Optional: declare custom marketplace catalogs
    marketplaces = [
      # GitHub shorthand
      "github:can1357/oh-my-pi-marketplace"
      # Local directory
      ./my-local-marketplace
    ];

    # Declare plugins to install
    plugins = [
      # 1. Official marketplace plugins (zero version required)
      "marketplace:clangd-lsp"

      # 2. Direct GitHub repositories (auto-registers catalog + plugin)
      "github:mariozechner/context-mode"

      # 3. Specific branch / tag
      "github:owner/repo@v1.2.0"

      # 4. Plugins from a specific marketplace
      "mock-extension@test-marketplace"

      # 5. Pure Nix flake inputs or local paths
      {
        name = "my-custom-plugin";
        src = ./my-plugin;
        # version and marketplace are optional
      }
    ];
  };
}
```

---

## Syntax Reference

### `programs.omp.plugins`

Accepts a list of strings, paths, or attribute sets:

| Format | Description | Example |
|---|---|---|
| `marketplace:<name>` | Resolves `<name>` from declared marketplaces or the official catalog | `"marketplace:clangd-lsp"` |
| `<name>@<marketplace>` | Resolves `<name>` specifically from `<marketplace>` | `"wordpress.com@claude-plugins-official"` |
| `<name>` | Resolves `<name>` across all declared marketplaces | `"clangd-lsp"` |
| `github:<owner>/<repo>[@ref]` | Clones GitHub repository, auto-detects catalog or creates an ad-hoc catalog | `"github:mariozechner/context-mode"` |
| `<owner>/<repo>[@ref]` | GitHub shorthand without `github:` prefix | `"mariozechner/context-mode@main"` |
| `path` | Local directory containing a plugin | `./my-local-plugin` |
| `{ name, src, version?, marketplace? }` | Pure Nix attribute set or flake input | `{ name = "sec"; src = inputs.sec; }` |

### `programs.omp.marketplaces`

Accepts a list of catalogs containing `.omp-plugin/marketplace.json` or `.claude-plugin/marketplace.json`:

| Format | Example |
|---|---|
| GitHub repository | `"github:anthropics/claude-plugins-official"` |
| GitHub shorthand | `"owner/catalog-repo"` |
| Local directory | `./my-team-marketplace` |
| Attribute set | `{ name = "internal"; src = ./catalog; }` |

### Options

| Option | Type | Default | Description |
|---|---|---|---|
| `programs.omp.enable` | `bool` | `false` | Enable declarative OMP plugin management |
| `programs.omp.plugins` | `listOf (either str (either path (attrsOf anything)))` | `[]` | List of plugins to install |
| `programs.omp.marketplaces` | `listOf (either str (either path (attrsOf anything)))` | `[]` | Custom marketplace catalogs |
| `programs.omp.officialMarketplace` | `nullOr (either path package)` | `inputs.claude-plugins-official` | Path to default official marketplace |
| `programs.omp.linkNodeModules` | `bool` | `true` | Symlink plugin packages into `node_modules` for OMP extensions |
| `programs.omp.linkLegacyDotOmp` | `bool` | `true` | Mirror registries to `~/.omp` for non-XDG compatibility |
| `programs.omp.disableAutoUpdate` | `bool` | `true` | Set `marketplace.autoUpdate: "off"` to prevent store write errors |

---

## Development & Verification

Build and inspect the synthesized JSON files without modifying `$HOME`:

```bash
# Build synthesized registries
nix build .#test-json

# Inspect generated files
jq . result/marketplaces.json
jq . result/installed_plugins.json
jq . result/omp-plugins.lock.json

# Run all flake checks
nix flake check
```

Inspect using the `omp` CLI:

```bash
XDG_DATA_HOME=result omp plugin marketplace list
XDG_DATA_HOME=result omp plugin list
XDG_DATA_HOME=result omp plugin discover
```

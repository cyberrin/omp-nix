{ defaultOfficialMarketplace ? null }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omp;
  pluginsLib = import ../lib/plugins.nix { inherit lib pkgs; };

  hasPlugins = cfg.plugins != [ ] || cfg.marketplaces != [ ] || cfg.officialMarketplace != null;

  resolved =
    if hasPlugins then
      pluginsLib.resolveAll {
        declaredMarketplaces = cfg.marketplaces;
        officialMarketplace = cfg.officialMarketplace;
        declaredPlugins = cfg.plugins;
      }
    else
      {
        uniqueMarketplaces = [ ];
        resolvedPlugins = [ ];
        npmPlugins = [ ];
        marketplacesJson = pkgs.writeText "marketplaces.json" (builtins.toJSON {
          version = 1;
          marketplaces = [ ];
        });
        installedPluginsJson = pkgs.writeText "installed_plugins.json" (builtins.toJSON {
          version = 2;
          plugins = { };
        });
        lockfileJson = pkgs.writeText "omp-plugins.lock.json" (builtins.toJSON {
          plugins = { };
          settings = { };
        });
      };
in
{
  options.programs.omp = {
    enable = lib.mkEnableOption "Oh My Pi (OMP) declarative plugin management";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "OMP package to install (optional, defaults to null when using system/flake omp).";
    };

    settings = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      description = "Declarative settings for OMP agent configuration.";
    };

    officialMarketplace = lib.mkOption {
      type = with lib.types; nullOr (either path (either package (attrsOf anything)));
      default = defaultOfficialMarketplace;
      description = ''
        Default official marketplace catalog containing .omp-plugin/marketplace.json
        or .claude-plugin/marketplace.json. Defaults to the pinned catalog from the flake.
      '';
    };

    marketplaces = lib.mkOption {
      type = with lib.types; listOf (either str (either path (attrsOf anything)));
      default = [ ];
      example = [
        "github:anthropics/claude-plugins-official"
        "./my-local-marketplace"
        {
          name = "custom";
          src = ./my-marketplace;
        }
      ];
      description = ''
        List of marketplace catalogs containing .omp-plugin/marketplace.json
        or .claude-plugin/marketplace.json. Can be:
        - GitHub shorthand: "owner/repo" or "github:owner/repo[@ref]"
        - Local path: ./path or "/path"
        - Attribute set: { name = "..."; src = ...; }
      '';
    };

    plugins = lib.mkOption {
      type = with lib.types; listOf (either str (either path (attrsOf anything)));
      default = [ ];
      example = [
        "marketplace:clangd-lsp"
        "github:mariozechner/context-mode"
        "clangd-lsp@claude-plugins-official"
        {
          name = "my-plugin";
          src = ./my-plugin;
        }
      ];
      description = ''
        List of plugins to declare and install. Can be:
        - Shorthand from configured marketplace: "marketplace:plugin-name" or "plugin-name@marketplace" or "plugin-name"
        - Direct repository: "github:owner/repo[@ref]" or "owner/repo"
        - Attribute set: { name = "..."; src = ...; version = "..."; marketplace = "..."; }
        - Direct flake input or local path
      '';
    };

    linkNodeModules = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to symlink plugin packages into node_modules and maintain omp-plugins.lock.json for runtime extensions.";
    };

    linkLegacyDotOmp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to also mirror registries into ~/.omp for fallback compatibility.";
    };

    disableAutoUpdate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to set marketplace.autoUpdate to 'off' to prevent OMP from attempting updates on read-only store files.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Optional package installation if specified
    (lib.mkIf (cfg.package != null) {
      home.packages = [ cfg.package ];
    })

    # Disable autoUpdate in programs.omp.settings if settings option is used
    (lib.mkIf cfg.disableAutoUpdate {
      programs.omp.settings = {
        marketplace = {
          autoUpdate = lib.mkDefault "off";
        };
      };
    })

    # Primary XDG data directory links (OMP looks in $XDG_DATA_HOME/omp)
    {
      xdg.dataFile."omp/marketplaces.json".source = resolved.marketplacesJson;
      xdg.dataFile."omp/plugins/installed_plugins.json".source = resolved.installedPluginsJson;
      xdg.configFile."omp/config.yml".text = lib.mkDefault ''
        marketplace:
          autoUpdate: "off"
      '';
    }

    # Optional node_modules and omp-plugins.lock.json links for extension plugins
    (lib.mkIf cfg.linkNodeModules {
      xdg.dataFile = lib.listToAttrs (
        map (p: {
          name = "omp/plugins/node_modules/${p.packageJson.name}";
          value = {
            source = p.installPath;
          };
        }) resolved.npmPlugins
      ) // {
        "omp/plugins/omp-plugins.lock.json".source = resolved.lockfileJson;
      };
    })

    # Optional legacy ~/.omp fallback symlinks
    (lib.mkIf cfg.linkLegacyDotOmp {
      home.file.".omp/marketplaces.json".source = resolved.marketplacesJson;
      home.file.".omp/plugins/installed_plugins.json".source = resolved.installedPluginsJson;
    })

    # Fallback activation to ensure ~/.omp/agent/config.yml has autoUpdate: off
    (lib.mkIf cfg.disableAutoUpdate {
      home.activation.ompDeclarativeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        $DRY_RUN_CMD mkdir -p "$HOME/.omp/agent"
        if [ ! -f "$HOME/.omp/agent/config.yml" ]; then
          $DRY_RUN_CMD cat << 'EOF' > "$HOME/.omp/agent/config.yml"
marketplace:
  autoUpdate: "off"
EOF
          $DRY_RUN_CMD chmod 600 "$HOME/.omp/agent/config.yml"
        fi
      '';
    })
  ]);
}

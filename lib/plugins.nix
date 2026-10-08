{ lib, pkgs }:
let
  # Strip leading and trailing whitespace
  trim = str:
    let
      matches = builtins.match "[[:space:]]*(.*[^[:space:]])[[:space:]]*" str;
    in
    if matches != null then builtins.head matches else "";

  # Strip leading "./" or "/" from path string
  cleanRelPath = pathStr:
    let
      s = toString pathStr;
    in
    if lib.hasPrefix "./" s then
      builtins.substring 2 (builtins.stringLength s - 2) s
    else if lib.hasPrefix "/" s then
      builtins.substring 1 (builtins.stringLength s - 1) s
    else
      s;

  # Check if a directory has a marketplace catalog file and read it
  # Priority: .omp-plugin/marketplace.json > .claude-plugin/marketplace.json > marketplace.json
  readCatalog = srcPath:
    let
      ompFile = "${srcPath}/.omp-plugin/marketplace.json";
      claudeFile = "${srcPath}/.claude-plugin/marketplace.json";
      rootFile = "${srcPath}/marketplace.json";
    in
    if builtins.pathExists ompFile then
      {
        path = "${srcPath}/.omp-plugin/marketplace.json";
        relPath = ".omp-plugin/marketplace.json";
        data = builtins.fromJSON (builtins.readFile ompFile);
      }
    else if builtins.pathExists claudeFile then
      {
        path = "${srcPath}/.claude-plugin/marketplace.json";
        relPath = ".claude-plugin/marketplace.json";
        data = builtins.fromJSON (builtins.readFile claudeFile);
      }
    else if builtins.pathExists rootFile then
      {
        path = "${srcPath}/marketplace.json";
        relPath = "marketplace.json";
        data = builtins.fromJSON (builtins.readFile rootFile);
      }
    else
      null;

  # Read package.json if present
  readPackageJson = dirPath:
    let
      pkgFile = "${dirPath}/package.json";
    in
    if builtins.pathExists pkgFile then
      builtins.fromJSON (builtins.readFile pkgFile)
    else
      null;

  # Read plugin.json if present (.omp-plugin, .claude-plugin, or root)
  readPluginJson = dirPath:
    let
      ompFile = "${dirPath}/.omp-plugin/plugin.json";
      claudeFile = "${dirPath}/.claude-plugin/plugin.json";
      rootFile = "${dirPath}/plugin.json";
    in
    if builtins.pathExists ompFile then
      builtins.fromJSON (builtins.readFile ompFile)
    else if builtins.pathExists claudeFile then
      builtins.fromJSON (builtins.readFile claudeFile)
    else if builtins.pathExists rootFile then
      builtins.fromJSON (builtins.readFile rootFile)
    else
      null;

  # Extract version following OMP priority:
  # 1. catalog version
  # 2. .claude-plugin/plugin.json / .omp-plugin/plugin.json
  # 3. package.json
  # 4. fallback
  detectVersion =
    {
      catalogVersion ? null,
      installPath,
      fallback ? "1.0.0",
    }:
    if catalogVersion != null && catalogVersion != "" then
      catalogVersion
    else
      let
        pJson = readPluginJson installPath;
        pkgJson = readPackageJson installPath;
      in
      if pJson != null && pJson ? version && pJson.version != null && pJson.version != "" then
        pJson.version
      else if pkgJson != null && pkgJson ? version && pkgJson.version != null && pkgJson.version != "" then
        pkgJson.version
      else
        fallback;

  # Parse git reference and owner/repo
  # Matches:
  # - github:owner/repo[@ref]
  # - owner/repo[@ref]
  # - https://github.com/owner/repo[.git][@ref]
  parseGitShorthand =
    spec:
    let
      # Check github:owner/repo[@ref]
      ghMatch = builtins.match "github:([^/@#]+)/([^@#]+)([@#](.+))?" spec;
      # Check owner/repo[@ref]
      shMatch = builtins.match "([^/@#]+)/([^@#]+)([@#](.+))?" spec;
      # Check https://github.com/owner/repo[.git][@ref]
      httpsMatch = builtins.match "https?://github\\.com/([^/@#]+)/([^@#]+?)(\\.git)?([@#](.+))?" spec;
    in
    if ghMatch != null then
      let
        owner = builtins.elemAt ghMatch 0;
        repo = builtins.elemAt ghMatch 1;
        ref = builtins.elemAt ghMatch 3;
      in
      {
        inherit owner repo;
        ref = if ref != null then ref else null;
        url = "https://github.com/${owner}/${repo}.git";
      }
    else if httpsMatch != null then
      let
        owner = builtins.elemAt httpsMatch 0;
        repo = builtins.elemAt httpsMatch 1;
        ref = builtins.elemAt httpsMatch 4;
      in
      {
        inherit owner repo;
        ref = if ref != null then ref else null;
        url = "https://github.com/${owner}/${repo}.git";
      }
    else if shMatch != null then
      let
        owner = builtins.elemAt shMatch 0;
        repo = builtins.elemAt shMatch 1;
        ref = builtins.elemAt shMatch 3;
      in
      {
        inherit owner repo;
        ref = if ref != null then ref else null;
        url = "https://github.com/${owner}/${repo}.git";
      }
    else
      null;

  # Fetch source from Git or resolve path
  fetchSource =
    src:
    if lib.isAttrs src && src ? outPath then
      src
    else if lib.isPath src then
      src
    else if lib.isString src then
      let
        isAbsolute = lib.hasPrefix "/" src;
        isRelative = lib.hasPrefix "./" src || lib.hasPrefix "../" src;
        gitInfo = parseGitShorthand src;
      in
      if isAbsolute then
        /. + src
      else if isRelative then
        throw "Relative path string '${src}' is ambiguous in pure Nix evaluation. Pass a path literal (e.g. ./path without quotes) instead."
      else if gitInfo != null then
        let
          isSha = gitInfo.ref != null && (builtins.match "^[0-9a-fA-F]{40}$" gitInfo.ref != null);
        in
        builtins.fetchGit (
          {
            url = gitInfo.url;
            allRefs = true;
          }
          // (lib.optionalAttrs (gitInfo.ref != null && isSha) {
            rev = gitInfo.ref;
          })
          // (lib.optionalAttrs (gitInfo.ref != null && !isSha) {
            ref = gitInfo.ref;
          })
        )
      else
        throw "Unsupported marketplace source: '${src}'. Expected 'owner/repo', 'github:owner/repo', or path literal."
    else
      throw "Invalid type for marketplace source: ${builtins.typeOf src}";

  # Normalize a declared marketplace entry:
  # Accepts:
  # - string: "owner/repo", "github:owner/repo", "./path"
  # - path: ./my-marketplace
  # - attrset: { name, src, catalogPath ? null } or flake input
  normalizeMarketplace =
    entry:
    let
      rawSrc =
        if lib.isAttrs entry && !(entry ? outPath) && entry ? src then
          entry.src
        else
          entry;
      storePath = fetchSource rawSrc;
      catalog = readCatalog storePath;
      explicitName =
        if lib.isAttrs entry && !(entry ? outPath) && entry ? name then
          entry.name
        else
          null;
      catalogName =
        if catalog != null && catalog.data ? name then
          catalog.data.name
        else if explicitName != null then
          explicitName
        else
          builtins.baseNameOf (toString storePath);

      # If catalog is not present, create a synthetic catalog
      effectiveCatalog =
        if catalog != null then
          catalog
        else
          let
            synth = {
              name = catalogName;
              owner = {
                name = "nix-declarative";
              };
              plugins = [ ];
            };
            synthFile = pkgs.writeText "${catalogName}-marketplace.json" (builtins.toJSON synth);
          in
          {
            path = "${synthFile}";
            relPath = "marketplace.json";
            data = synth;
          };
    in
    {
      name = catalogName;
      sourceUri = toString storePath;
      catalogPath = effectiveCatalog.path;
      catalogData = effectiveCatalog.data;
    };

  # Helper to resolve plugin source when defined inside a catalog
  resolveCatalogPluginSource =
    {
      mktStorePath,
      catalogData,
      pluginDef,
    }:
    let
      rawSource = pluginDef.source or "./";
      pluginRoot =
        if catalogData ? metadata && catalogData.metadata ? pluginRoot then
          cleanRelPath catalogData.metadata.pluginRoot
        else
          "";
    in
    if lib.isString rawSource then
      let
        cleanSrc = cleanRelPath rawSource;
        rel =
          if pluginRoot != "" && cleanSrc != "" then
            "${pluginRoot}/${cleanSrc}"
          else if pluginRoot != "" then
            pluginRoot
          else
            cleanSrc;
      in
      if rel == "" || rel == "." then
        mktStorePath
      else
        "${mktStorePath}/${rel}"
    else if lib.isAttrs rawSource then
      let
        variant = rawSource.source or "url";
      in
      if variant == "git-subdir" then
        let
          url =
            if lib.hasPrefix "http" rawSource.url || lib.hasPrefix "git@" rawSource.url then
              rawSource.url
            else
              "https://github.com/${rawSource.url}.git";
          repo = builtins.fetchGit (
            {
              inherit url;
              allRefs = true;
            }
            // (lib.optionalAttrs (rawSource ? sha) {
              rev = rawSource.sha;
            })
            // (lib.optionalAttrs (rawSource ? ref && !(rawSource ? sha)) {
              ref = rawSource.ref;
            })
          );
        in
        "${repo}/${cleanRelPath rawSource.path}"
      else if variant == "github" then
        let
          url = "https://github.com/${rawSource.repo}.git";
          repo = builtins.fetchGit (
            {
              inherit url;
              allRefs = true;
            }
            // (lib.optionalAttrs (rawSource ? sha) {
              rev = rawSource.sha;
            })
            // (lib.optionalAttrs (rawSource ? ref && !(rawSource ? sha)) {
              ref = rawSource.ref;
            })
          );
        in
        toString repo
      else if variant == "url" then
        let
          repo = builtins.fetchGit (
            {
              url = rawSource.url;
              allRefs = true;
            }
            // (lib.optionalAttrs (rawSource ? sha) {
              rev = rawSource.sha;
            })
            // (lib.optionalAttrs (rawSource ? ref && !(rawSource ? sha)) {
              ref = rawSource.ref;
            })
          );
        in
        toString repo
      else
        throw "Unsupported catalog plugin source object variant: '${variant}'"
    else
      throw "Invalid type for plugin source in catalog: ${builtins.typeOf rawSource}";

  # Resolve a single plugin specification against configured marketplaces
  # pluginSpec can be:
  # - "github:owner/repo[@ref]" or "owner/repo[@ref]"
  # - "marketplace:plugin-name"
  # - "plugin-name@marketplace-name"
  # - "plugin-name" (searches marketplaces)
  # - { name, src, version ?, marketplace ? } or flake input directly
  resolvePlugin =
    {
      pluginSpec,
      marketplaces, # List of normalized marketplaces
    }:
    if lib.isAttrs pluginSpec && !(pluginSpec ? outPath) && pluginSpec ? src then
      # Explicit attrset { name ?, src, version ?, marketplace ? }
      let
        storePath = fetchSource pluginSpec.src;
        catalog = readCatalog storePath;
        pkgJson = readPackageJson storePath;
        pJson = readPluginJson storePath;

        name =
          if pluginSpec ? name then
            pluginSpec.name
          else if catalog != null && catalog.data ? name then
            catalog.data.name
          else if pkgJson != null && pkgJson ? name then
            pkgJson.name
          else if pJson != null && pJson ? name then
            pJson.name
          else
            builtins.baseNameOf (toString storePath);

        mktName =
          if pluginSpec ? marketplace then
            pluginSpec.marketplace
          else if catalog != null && catalog.data ? name then
            catalog.data.name
          else
            "nix-declarative";

        version =
          if pluginSpec ? version then
            pluginSpec.version
          else
            detectVersion {
              installPath = toString storePath;
              fallback = "1.0.0";
            };

        # Generate an ad-hoc catalog entry if not part of an existing marketplace
        adHocCatalog =
          if catalog != null then
            {
              name = mktName;
              sourceUri = toString storePath;
              catalogPath = catalog.path;
              catalogData = catalog.data;
            }
          else
            let
              synth = {
                name = mktName;
                owner = {
                  name = "nix-declarative";
                };
                plugins = [
                  {
                    inherit name version;
                    source = "./";
                  }
                ];
              };
              synthFile = pkgs.writeText "${mktName}-marketplace.json" (builtins.toJSON synth);
            in
            {
              name = mktName;
              sourceUri = toString storePath;
              catalogPath = "${synthFile}";
              catalogData = synth;
            };
      in
      {
        inherit name version;
        marketplace = mktName;
        installPath = toString storePath;
        marketplaceEntry = adHocCatalog;
        packageJson = pkgJson;
      }
    else if lib.isAttrs pluginSpec && pluginSpec ? outPath then
      # Flake input directly passed as plugin
      resolvePlugin {
        pluginSpec = {
          src = pluginSpec;
        };
        inherit marketplaces;
      }
    else if lib.isPath pluginSpec then
      # Local path directly passed
      resolvePlugin {
        pluginSpec = {
          src = pluginSpec;
        };
        inherit marketplaces;
      }
    else if lib.isString pluginSpec then
      let
        # Check if direct repo format: github:owner/repo or owner/repo or git url
        gitInfo = parseGitShorthand pluginSpec;
        mpMatch = builtins.match "marketplace:(.+)" pluginSpec;
      in
      if mpMatch != null then
        # Format: "marketplace:plugin-name"
        let
          targetName = builtins.elemAt mpMatch 0;
          # Search across all marketplaces
          findInMarketplaces = lib.filter (
            m: lib.any (p: p.name == targetName) (m.catalogData.plugins or [ ])
          ) marketplaces;
          matchedMkt =
            if findInMarketplaces == [ ] then
              throw "OMP plugin '${targetName}' not found in any declared marketplaces!"
            else
              lib.head findInMarketplaces;
          pluginDef = lib.head (
            lib.filter (p: p.name == targetName) (matchedMkt.catalogData.plugins or [ ])
          );
          installPath = resolveCatalogPluginSource {
            mktStorePath = matchedMkt.sourceUri;
            catalogData = matchedMkt.catalogData;
            inherit pluginDef;
          };
          version = detectVersion {
            catalogVersion = pluginDef.version or null;
            inherit installPath;
          };
          pkgJson = readPackageJson installPath;
        in
        {
          name = targetName;
          marketplace = matchedMkt.name;
          inherit version installPath;
          marketplaceEntry = null; # Already in marketplaces
          packageJson = pkgJson;
        }
      else if gitInfo != null then
        # Format: "github:owner/repo[@ref]" or "owner/repo"
        let
          storePath = fetchSource pluginSpec;
          catalog = readCatalog storePath;
          pkgJson = readPackageJson storePath;
          pJson = readPluginJson storePath;

          # Check if catalog exists in the repo
          mktName =
            if catalog != null && catalog.data ? name then
              catalog.data.name
            else
              gitInfo.repo;

          # If the repo contains a catalog with plugins, resolve the targeted plugin
          matchedPlugin =
            if catalog != null && catalog.data ? plugins && builtins.length catalog.data.plugins > 0 then
              let
                matchingByName = lib.filter (p: p.name == gitInfo.repo) catalog.data.plugins;
              in
              if matchingByName != [ ] then
                lib.head matchingByName
              else
                lib.head catalog.data.plugins
            else
              null;

          pluginName =
            if matchedPlugin != null then
              matchedPlugin.name
            else if pkgJson != null && pkgJson ? name then
              pkgJson.name
            else if pJson != null && pJson ? name then
              pJson.name
            else
              gitInfo.repo;

          installPath =
            if matchedPlugin != null then
              resolveCatalogPluginSource {
                mktStorePath = toString storePath;
                catalogData = catalog.data;
                pluginDef = matchedPlugin;
              }
            else
              toString storePath;

          version = detectVersion {
            catalogVersion = if matchedPlugin != null then matchedPlugin.version or null else null;
            inherit installPath;
            fallback = if gitInfo.ref != null then gitInfo.ref else "1.0.0";
          };

          # Create ad-hoc marketplace entry
          adHocCatalog =
            if catalog != null then
              {
                name = mktName;
                sourceUri = toString storePath;
                catalogPath = catalog.path;
                catalogData = catalog.data;
              }
            else
              let
                synth = {
                  name = mktName;
                  owner = {
                    name = gitInfo.owner;
                  };
                  plugins = [
                    {
                      name = pluginName;
                      inherit version;
                      source = "./";
                    }
                  ];
                };
                synthFile = pkgs.writeText "${mktName}-marketplace.json" (builtins.toJSON synth);
              in
              {
                name = mktName;
                sourceUri = toString storePath;
                catalogPath = "${synthFile}";
                catalogData = synth;
              };
        in
        {
          name = pluginName;
          marketplace = mktName;
          inherit version installPath;
          marketplaceEntry = adHocCatalog;
          packageJson = readPackageJson installPath;
        }
      else
        # Format: "plugin-name@marketplace-name" or "plugin-name"
        let
          parts = lib.splitString "@" pluginSpec;
          targetName = builtins.elemAt parts 0;
          targetMkt = if builtins.length parts > 1 then builtins.elemAt parts 1 else null;
          findInMarketplaces = lib.filter (
            m:
            (targetMkt == null || m.name == targetMkt)
            && (lib.any (p: p.name == targetName) (m.catalogData.plugins or [ ]))
          ) marketplaces;
          matchedMkt =
            if findInMarketplaces == [ ] then
              throw "OMP plugin '${pluginSpec}' not found in any declared marketplaces!"
            else if targetMkt == null && builtins.length findInMarketplaces > 1 then
              let
                names = lib.concatStringsSep ", " (map (m: m.name) findInMarketplaces);
              in
              throw "OMP plugin '${targetName}' is present in multiple marketplaces (${names}). Qualify it as '${targetName}@<marketplace>'."
            else
              lib.head findInMarketplaces;
          pluginDef = lib.head (
            lib.filter (p: p.name == targetName) (matchedMkt.catalogData.plugins or [ ])
          );
          installPath = resolveCatalogPluginSource {
            mktStorePath = matchedMkt.sourceUri;
            catalogData = matchedMkt.catalogData;
            inherit pluginDef;
          };
          version = detectVersion {
            catalogVersion = pluginDef.version or null;
            inherit installPath;
          };
        in
        {
          name = targetName;
          marketplace = matchedMkt.name;
          inherit version installPath;
          marketplaceEntry = null;
          packageJson = readPackageJson installPath;
        }
    else
      throw "Invalid type for OMP plugin spec: ${builtins.typeOf pluginSpec}";

  # Resolve all configured marketplaces and plugins
  resolveAll =
    {
      declaredMarketplaces, # list of user marketplaces
      officialMarketplace ? null, # optional default official marketplace
      declaredPlugins, # list of user plugin specs
    }:
    let
      # Base list of raw marketplaces
      baseMarketplaces =
        (lib.optional (officialMarketplace != null) officialMarketplace) ++ declaredMarketplaces;

      # Normalize all base marketplaces
      normalizedMarketplaces = map normalizeMarketplace baseMarketplaces;

      # Resolve all plugins
      resolvedPlugins = map (
        p:
        resolvePlugin {
          pluginSpec = p;
          marketplaces = normalizedMarketplaces;
        }
      ) declaredPlugins;

      # Extract ad-hoc marketplaces created by direct repo / attrset plugins
      adHocMarketplaces = lib.filter (m: m != null) (map (p: p.marketplaceEntry) resolvedPlugins);

      # Combine and deduplicate all marketplaces by name
      combinedMarketplaces = normalizedMarketplaces ++ adHocMarketplaces;
      uniqueMarketplaces = lib.unique (
        lib.foldl' (
          acc: m:
          if lib.any (existing: lib.toLower existing.name == lib.toLower m.name) acc then
            acc
          else
            acc ++ [ m ]
        ) [ ] combinedMarketplaces
      );

      # Synthesize marketplaces.json (Schema v1)
      marketplacesJson = pkgs.writeText "marketplaces.json" (
        builtins.toJSON {
          version = 1;
          marketplaces = map (m: {
            name = m.name;
            sourceType = "local";
            sourceUri = m.sourceUri;
            catalogPath = m.catalogPath;
            addedAt = "1970-01-01T00:00:00.000Z";
            updatedAt = "1970-01-01T00:00:00.000Z";
            lastUpdated = "1970-01-01T00:00:00.000Z";
            autoUpdate = "off";
          }) uniqueMarketplaces;
        }
      );

      # Synthesize installed_plugins.json (Schema v2)
      installedPluginsJson = pkgs.writeText "installed_plugins.json" (
        builtins.toJSON {
          version = 2;
          plugins = lib.listToAttrs (
            map (p: {
              name = "${p.name}@${p.marketplace}";
              value = [
                {
                  scope = "user";
                  installPath = p.installPath;
                  version = p.version;
                  installedAt = "1970-01-01T00:00:00.000Z";
                  lastUpdated = "1970-01-01T00:00:00.000Z";
                  enabled = true;
                }
              ];
            }) resolvedPlugins
          );
        }
      );

      # Filter plugins that have a package.json for node_modules and omp-plugins.lock.json
      npmPlugins = lib.filter (p: p.packageJson != null && p.packageJson ? name) resolvedPlugins;

      # Synthesize omp-plugins.lock.json
      lockfileJson = pkgs.writeText "omp-plugins.lock.json" (
        builtins.toJSON {
          plugins = lib.listToAttrs (
            map (p: {
              name = p.packageJson.name;
              value = {
                version = p.version;
                enabledFeatures = null;
                enabled = true;
              };
            }) npmPlugins
          );
          settings = { };
        }
      );
    in
    {
      inherit
        uniqueMarketplaces
        resolvedPlugins
        npmPlugins
        marketplacesJson
        installedPluginsJson
        lockfileJson
        ;
    };
in
{
  inherit
    cleanRelPath
    readCatalog
    readPackageJson
    readPluginJson
    detectVersion
    parseGitShorthand
    fetchSource
    normalizeMarketplace
    resolveCatalogPluginSource
    resolvePlugin
    resolveAll
    ;
}

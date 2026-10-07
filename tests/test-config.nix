{ ... }:
{
  home.username = "testuser";
  home.homeDirectory = "/home/testuser";
  home.stateVersion = "24.05";

  programs.omp = {
    enable = true;
    marketplaces = [
      ./mock-marketplace
    ];
    plugins = [
      "marketplace:clangd-lsp"
      "marketplace:mock-plugin"
      "mock-extension@test-marketplace"
      {
        name = "mock-standalone";
        src = ./mock-standalone-plugin;
      }
    ];
  };
}

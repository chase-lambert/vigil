{
  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = { zig2nix, ... }: let
    flake-utils = zig2nix.inputs.flake-utils;
  in (flake-utils.lib.eachDefaultSystem (system: let
    env = zig2nix.outputs.zig-env.${system} { zig = zig2nix.outputs.packages.${system}.zig-0_15_2; };
    pkgs = env.pkgs;
    lib = pkgs.lib;
  in rec {
    # nix build .#foreign
    # Produces clean binaries meant to be shipped outside of nix
    packages.foreign = env.package {
      src = lib.cleanSource ./.;

      # Packages required for compiling
      nativeBuildInputs = [];
      # Packages required for linking
      buildInputs = [];

      zigBuildFlags = [ "-Doptimize=ReleaseFast" ];

      # Smaller binaries, avoids shipping glibc
      zigPreferMusl = true;

      meta = {
        mainProgram = "vigil";
        description = "A clean, fast build watcher for Zig";
        homepage = "https://github.com/chase-lambert/vigil";
        license = lib.licenses.mit;
        platforms = lib.platforms.linux;
      };
    };

    # nix build .
    packages.default = packages.foreign.override (attrs: {
      # Prefer nix friendly settings
      zigPreferMusl = false;

      # Executables required for runtime
      # These packages will be added to the PATH
      zigWrapperBins = [];

      # Libraries required for runtime
      # These packages will be added to the LD_LIBRARY_PATH
      zigWrapperLibs = attrs.buildInputs or [];
    });

    # For bundling with nix bundle for running outside of nix
    # example: https://github.com/ralismark/nix-appimage
    apps.bundle = {
      type = "app";
      program = "${packages.foreign}/bin/@SED_ZIG_BIN@";
    };

    # nix run .
    apps.default = env.app [] "zig build run -- \"$@\"";

    # nix run .#build
    apps.build = env.app [] "zig build \"$@\"";

    # nix run .#test
    apps.test = env.app [] "zig build test -- \"$@\"";

    # nix run .#docs
    apps.docs = env.app [] "zig build docs -- \"$@\"";

    # nix run .#zig2nix
    # Use `nix run path:.#zig2nix zon2lock` to update the zon2json-lock file.
    apps.zig2nix = env.app [] "zig2nix \"$@\"";

    # nix develop
    devShells.default = env.mkShell {
      # Packages required for compiling, linking and running
      # Libraries added here will be automatically added to the LD_LIBRARY_PATH and PKG_CONFIG_PATH
      nativeBuildInputs = []
        ++ packages.default.nativeBuildInputs
        ++ packages.default.buildInputs
        ++ packages.default.zigWrapperBins
        ++ packages.default.zigWrapperLibs;
    };
  }));
}

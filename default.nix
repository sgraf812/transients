{ nixpkgs ? import <nixpkgs> {}, compiler ? "ghc8107" }:
nixpkgs.haskell.lib.doBenchmark ((nixpkgs.pkgs.haskell.packages.${compiler}.override {
  overrides = self: super: {
    # src = ../cabal-toolkit;
  };
}).callPackage ./transients.nix { })

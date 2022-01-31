{ mkDerivation, base, containers, criterion, deepseq, directory
, doctest, filepath, ghc-prim, hlint, lens, lib, parallel
, primitive, unordered-containers
}:
mkDerivation {
  pname = "transients";
  version = "0";
  src = ./.;
  libraryHaskellDepends = [ base deepseq ghc-prim lens primitive ];
  testHaskellDepends = [
    base directory doctest filepath hlint parallel
  ];
  benchmarkHaskellDepends = [
    base containers criterion deepseq ghc-prim lens primitive
    unordered-containers
  ];
  homepage = "http://github.com/ekmett/transients/";
  description = "Transients";
  license = lib.licenses.bsd3;
}

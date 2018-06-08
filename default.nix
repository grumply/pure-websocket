{ mkDerivation, ghc, ghcjs-base, base, bytestring
, io-streams, network, random, HsOpenSSL, openssl-streams, websockets
, stdenv, template-haskell, text
, unordered-containers
, pure-txt, pure-json, pure-lifted
, secure ? false
, debugws ? false
, debugapi ? false
, devel ? false
, useTemplateHaskell ? true
}:
mkDerivation {
  pname = "pure-websocket";
  version = "0.7.0.0";
  src = ./.;
  libraryHaskellDepends = [
    base bytestring text unordered-containers pure-lifted pure-txt pure-json
  ] ++ (if useTemplateHaskell then [ template-haskell ] else [])
    ++ (if ghc.isGhcjs or false then [ ghcjs-base ] else [
        io-streams network random websockets
    ] ++ (if secure then [ HsOpenSSL openssl-streams ] else [])
    );
  configureFlags =
    [ (secure ? "-fsecure")
      (debugws ? "-fdebugws")
      (debugapi ? "-fdebugapi")
      (devel ? "-fdevel")
    ] ++ (if useTemplateHaskell then [] else [
      "-f-use-template-haskell"
    ]);
  homepage = "github.com/grumply/pure-websocket";
  license = stdenv.lib.licenses.bsd3;
}

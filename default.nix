{ mkDerivation, ghc, ghcjs-base, base, bytestring
, io-streams, network, random, HsOpenSSL, openssl-streams, websockets
, stdenv, template-haskell, text, mtl
, unordered-containers
, pure-txt, pure-json, pure-lifted, pure-time
}:
mkDerivation {
  pname = "pure-websocket";
  version = "0.8.0.0";
  src = ./.;
  libraryHaskellDepends = [
    base bytestring text unordered-containers pure-lifted pure-txt pure-json mtl pure-time template-haskell
    ] ++ (if ghc.isGhcjs or false 
        then [ ghcjs-base ] 
        else [ io-streams network random websockets HsOpenSSL openssl-streams ] 
    );
  homepage = "github.com/grumply/pure-websocket";
  license = stdenv.lib.licenses.bsd3;
}

{-# language CPP #-}
module Pure.WebSocket.Internal (module Export) where

#ifdef __GHCJS__
import Pure.WebSocket.Internal.GHCJS as Export
#else
import Pure.WebSocket.Internal.GHC   as Export
#endif
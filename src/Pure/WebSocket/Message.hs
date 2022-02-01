{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeFamilies #-}
module Pure.WebSocket.Message where

-- from pure-txt
import Pure.Data.Txt

-- from pure-websocket (local)
import Pure.WebSocket.Identify
import Pure.WebSocket.TypeRep

-- from base
import Data.Typeable
import Data.Monoid

class Typeable (msgTy :: *) => Message msgTy where
  type M msgTy :: *
  {-# INLINE messageHeader #-}
  messageHeader :: Proxy msgTy -> Txt
  default messageHeader :: Proxy msgTy -> Txt
  messageHeader = rep
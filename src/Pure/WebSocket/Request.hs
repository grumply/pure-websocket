{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeFamilies #-}
module Pure.WebSocket.Request where

-- from pure-txt
import Pure.Data.Txt

-- from base
import Data.Monoid
import Data.Typeable

-- from pure-websocket (local)
import Pure.WebSocket.Identify
import Pure.WebSocket.TypeRep

class (Typeable (requestType :: *)) => Request requestType where
  type Req requestType :: *
  type Rsp requestType :: *

  requestHeader :: Proxy requestType -> Txt
  {-# INLINE requestHeader #-}
  default requestHeader :: Proxy requestType -> Txt
  requestHeader = rep

  responseHeader :: (Req requestType ~ request) => Proxy requestType -> request -> Txt
  {-# INLINE responseHeader #-}
  default responseHeader :: ( Req requestType ~ request
                            , Identify request
                            , I request ~ requestIdentity
                            , ToTxt requestIdentity
                            )
                        => Proxy requestType -> request -> Txt
  responseHeader = rspHdr

rspHdr :: ( Typeable requestType
                , Request requestType
                , Req requestType ~ request
                , Identify request
                , I request ~ requestIdentity
                , ToTxt requestIdentity
                )
             => Proxy requestType -> request -> Txt
rspHdr rqty_proxy req = rep rqty_proxy <> " " <> toTxt (identify req)
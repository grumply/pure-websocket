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
  requestHeader = qualReqHdr

  responseHeader :: (Req requestType ~ request) => Proxy requestType -> request -> Txt
  {-# INLINE responseHeader #-}
  default responseHeader :: ( Req requestType ~ request
                            , Identify request
                            , I request ~ requestIdentity
                            , ToTxt requestIdentity
                            )
                        => Proxy requestType -> request -> Txt
  responseHeader = qualRspHdr

simpleReqHdr :: forall (requestType :: *). Typeable requestType => Proxy requestType -> Txt
simpleReqHdr = rep

qualReqHdr :: forall (requestType :: *). Typeable requestType => Proxy requestType -> Txt
qualReqHdr = qualRep

fullReqHdr :: forall (requestType :: *). Typeable requestType => Proxy requestType -> Txt
fullReqHdr = fullRep

simpleRspHdr :: ( Typeable requestType
                , Request requestType
                , Req requestType ~ request
                , Identify request
                , I request ~ requestIdentity
                , ToTxt requestIdentity
                )
             => Proxy requestType -> request -> Txt
simpleRspHdr rqty_proxy req = rep rqty_proxy <> " " <> toTxt (identify req)

qualRspHdr :: ( Typeable requestType
              , Request requestType
              , Req requestType ~ request
              , Identify request
              , I request ~ requestIdentity
              , ToTxt requestIdentity
              )
           => Proxy requestType -> request -> Txt
qualRspHdr rqty_proxy req = qualRep rqty_proxy <> " " <> toTxt (identify req)

fullRspHdr :: ( Typeable requestType
              , Request requestType
              , Req requestType ~ request
              , Identify request
              , I request ~ requestIdentity
              , ToTxt requestIdentity
              )
           => Proxy requestType -> request -> Txt
fullRspHdr rqty_proxy req = fullRep rqty_proxy <> " " <> toTxt (identify req)


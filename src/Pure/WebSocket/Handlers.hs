{-# LANGUAGE CPP, TypeOperators, GADTs, FlexibleContexts, DataKinds, TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses, UndecidableInstances, TypeFamilies, ScopedTypeVariables #-}
module Pure.WebSocket.Handlers where

-- from base
import Data.Proxy
import Unsafe.Coerce

-- from pure-txt
import Pure.Data.Txt (Txt)

-- from pure-json
import Pure.Data.JSON

-- from pure-websocket (local)
import Pure.WebSocket.API
import Pure.WebSocket.Callbacks
import Pure.WebSocket.Dispatch
import Pure.WebSocket.Endpoint
import Pure.WebSocket.Identify
import Pure.WebSocket.Message
import Pure.WebSocket.Request
#ifdef __GHCJS__
import Pure.WebSocket.GHCJS
#else
import Pure.WebSocket.GHC
#endif

data ActiveEndpoints es
  where
    ActiveEndpointsNull
      :: ActiveEndpoints '[]

    ActiveEndpointsCons
      :: Proxy e
      -> Endpoint a
      -> ActiveEndpoints es
      -> ActiveEndpoints (e ': es)

class EnactEndpoints api_ty hndlr es es' where
  -- we take api_ty's es to be our fixed basis
  enactEndpoints :: WebSocket
                 -> api_ty es
                 -> Endpoints hndlr es'
                 -> IO (ActiveEndpoints es)

instance EnactEndpoints api_ty hndlr '[] '[] where
  enactEndpoints _ _ _ = return ActiveEndpointsNull

data ActiveAPI messages requests =
  ActiveAPI (ActiveEndpoints messages) (ActiveEndpoints requests)

type family Equal a b :: Bool
  where

    Equal a a = 'True

    Equal a b = 'False

data RequestHandler rqTy
  where
    RequestHandler
      :: (Request rqTy, Req rqTy ~ request, Identify request, I request ~ rqI, FromJSON request, Rsp rqTy ~ response, ToJSON response)
      => Proxy rqTy
      -> RequestCallback request response
      -> RequestHandler rqTy

-- | Construct a well-typed request handler.
--
-- Given a request type:
--
-- > data Ping = Ping
-- > data Pong = Pong
-- > ping = Proxy :: Proxy Ping
-- > instance Request Ping where
-- >   Req Ping = Ping
-- >   Rsp Ping = Pong
--
-- Or:
--
-- > mkMessage "Ping" [t|Ping -> Pong|]
--
-- Create a handler with:
--
-- > responds ping $ \done -> \case
-- >   Left dsp -> ...
-- >   Right (respond,Ping) -> liftIO $ respond (Right Pong)
responds :: (Request rqTy, Req rqTy ~ request, Identify request, I request ~ rqI, FromJSON request, Rsp rqTy ~ response, ToJSON response)
         => Proxy rqTy
         -> RequestCallback request response
         -> RequestHandler rqTy
responds = RequestHandler

type ReqHandlers rqs = Endpoints RequestHandler rqs

data MessageHandler mTy
  where
    MessageHandler
      :: (Message mTy, M mTy ~ msg, ToJSON msg)
      => Proxy mTy
      -> (IO () -> Either Dispatch msg -> IO ())
      -> MessageHandler mTy

-- | Construct a well-typed message handler.
--
-- Given a message type:
--
-- > data HeartBeat
-- > heartbeat = Proxy :: Proxy (HeartBeat)
-- > instance Message HeartBeat where
-- >   type M HeartBeat = ()
--
-- Or:
--
-- > mkMessage "HeartBeat" [t|()|]
--
-- Create a handler with:
--
-- > accepts heartbeat $ \done -> \case
-- >   Left dsp -> ...
-- >   Right () -> ...
accepts :: (Message mTy, M mTy ~ msg, ToJSON msg)
        => Proxy mTy
        -> (IO () -> Either Dispatch msg -> IO ())
        -> MessageHandler mTy
accepts = MessageHandler

type MsgHandlers msgs = Endpoints MessageHandler msgs

instance ( GetHandler MessageHandler message msgs'
         , Removed msgs' message ~ msgs''
         , DeleteHandler MessageHandler message msgs' msgs''
         , EnactEndpoints MessageAPI MessageHandler msgs msgs''
         , Message message
         , M message ~ msg
         , ToJSON msg
         , FromJSON msg
         )
  => EnactEndpoints MessageAPI MessageHandler (message ': msgs) msgs' where
  enactEndpoints ws_ (APICons pm ms) mhs = do
    case getHandler mhs :: MessageHandler message of
      MessageHandler _ f -> do
        let p = Proxy :: Proxy message
            mhs' = deleteHandler p mhs :: MsgHandlers msgs''
        amh <- onMessage ws_ p f
                 -- ((unsafeCoerce f) :: IO () -> Either Dispatch msg -> IO ())
        ams <- enactEndpoints ws_ ms mhs'
        return $ ActiveEndpointsCons pm (Endpoint (messageHeader p) amh) ams

instance ( GetHandler RequestHandler request rqs'
         , Removed rqs' request ~ rqs''
         , DeleteHandler RequestHandler request rqs' rqs''
         , EnactEndpoints RequestAPI RequestHandler rqs rqs''
         , Request request
         , Req request ~ req
         , Rsp request ~ response
         , ToJSON req
         , FromJSON response
         )
  => EnactEndpoints RequestAPI RequestHandler (request ': rqs) rqs' where
  enactEndpoints ws_ (APICons pm ms) mhs =
    case getHandler mhs :: RequestHandler request of
      RequestHandler _ f -> do
        let p = Proxy :: Proxy request
            mhs' = deleteHandler p mhs :: ReqHandlers rqs''
        amh <- respond ws_ p f
                 -- ((unsafeCoerce f) :: IO () -> Either Dispatch (Either LazyByteString response -> IO (Either Status ()),req) -> IO ())
        ams <- enactEndpoints ws_ ms mhs'
        return $ ActiveEndpointsCons pm (Endpoint (requestHeader p) amh) ams

data Implementation msgs rqs msgs' rqs'
  where
    Impl
      :: ( EnactEndpoints MessageAPI MessageHandler msgs msgs'
         , EnactEndpoints RequestAPI RequestHandler rqs rqs'
         )
      => FullAPI msgs rqs
      -> Endpoints MessageHandler msgs'
      -> Endpoints RequestHandler rqs'
      -> Implementation msgs rqs msgs' rqs'

-- | Given two distinct API implementations, combine them into one implementation.
--
-- The type is rather hairy. Note that `TListAppend` guarantees uniqueness.
--
-- (<+++>) :: (TListAppend (Endpoints RequestHandler c) rqsl' rqsr' rqs'
--            ,TListAppend (Endpoints MessageHandler c) msgsl' msgsr' msgs'
--            ,TListAppend (API Request) rqsl rqsr rqs
--            ,TListAppend (API Message) msgsl msgsr msgs
--            ,EnactEndpoints RequestAPI RequestHandler rqs rqs'
--            ,EnactEndpoints MessageAPI MessageHandler msgs msgs'
--            )
--         => Implementation msgsl rqsl msgsl' rqsl'
--         -> Implementation msgsr rqsr msgsr' rqsr'
--         -> Implementation msgs rqs msgs' rqs'
(Impl (API ml rl) eml erl) <+++> (Impl (API mr rr) emr err) =
  Impl (API (ml <++> mr) (rl <++> rr)) (eml <++> emr) (erl <++> err)

-- | Given an Implementation of an API, execute the implementation and return a corresponding ActiveAPI.
enact :: WebSocket -> Implementation msgs rqs msgs' rqs' -> IO (ActiveAPI msgs rqs)
enact ws_ (Impl local mhs rhs) = do
  let API mapi rapi = local
  amapi <- enactEndpoints ws_ mapi mhs
  arapi <- enactEndpoints ws_ rapi rhs
  let active = ActiveAPI amapi arapi
  return active


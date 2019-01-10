{-# LANGUAGE CPP, FlexibleContexts, RankNTypes, TypeApplications, LambdaCase, TypeOperators, ScopedTypeVariables, GADTs, DataKinds #-}
#ifdef USE_TEMPLATE_HASKELL
{-# LANGUAGE TemplateHaskell #-}
#endif
{-# LANGUAGE ViewPatterns #-}
module Pure.WebSocket
  (
#ifdef USE_TEMPLATE_HASKELL
    mkRequest,
    mkMessage,
#endif
    remote,
    remoteDebug,
    notify,
    Responding,
    reply,
    done,
    req,
    handle,
    module Export
  ) where

import Pure.Data.JSON (ToJSON,FromJSON,logJSON)
import Pure.Data.Txt (Txt)
import Pure.Data.Time (time)

#ifdef __GHCJS__
import Pure.WebSocket.GHCJS     as Export
#else
import Pure.WebSocket.GHC       as Export
#endif

import Pure.WebSocket.API       as Export
import Pure.WebSocket.Callbacks as Export
import Pure.WebSocket.Dispatch  as Export
import Pure.WebSocket.Endpoint  as Export
import Pure.WebSocket.Handlers  as Export
import Pure.WebSocket.Identify  as Export
import Pure.WebSocket.Message   as Export
import Pure.WebSocket.Request   as Export
import Pure.WebSocket.TypeRep   as Export

import Control.Concurrent
import Control.Monad
import Data.Char
import Data.Foldable
import Data.Proxy
import Data.Unique

import Control.Monad.Reader as R

#ifdef USE_TEMPLATE_HASKELL
import Language.Haskell.TH
import Language.Haskell.TH.Lib
#endif

mapHead f [] = []
mapHead f (x:xs) = f x : xs

#ifdef USE_TEMPLATE_HASKELL
processName str = (mkName str,mkName $ mapHead toLower str)

mkRequest :: String -> TypeQ -> Q [Dec]
mkRequest (processName -> (dat,rq))  ty = do
  rr <- ty
  case rr of
    (AppT (AppT ArrowT req) rsp) -> do
      let dataDec = DataD [] dat [] Nothing [] []
          proxyFunTy  = SigD rq (ConT ''Proxy `AppT` ConT dat)
          proxyFunDec = FunD rq [ Clause [] (NormalB (ConE 'Proxy)) [] ]
          requestInstanceDec = InstanceD Nothing [] (ConT ''Request `AppT` ConT dat)
            [ TySynInstD ''Req (TySynEqn [ ConT dat ] (AppT (AppT (TupleT 2) (ConT ''Int)) req))
            , TySynInstD ''Rsp (TySynEqn [ ConT dat ] rsp)
            ]
      return [dataDec,proxyFunTy,proxyFunDec,requestInstanceDec]
    _ -> error $ "Invalid request type for " ++ show dat

mkMessage :: String -> TypeQ -> Q [Dec]
mkMessage (processName -> (dat,msg)) ty = do
  message <- ty
  let dataDec = DataD [] dat [] Nothing [] []
      proxyFunTy  = SigD msg (ConT ''Proxy `AppT` ConT dat)
      proxyFunDec = FunD msg [ Clause [] (NormalB (ConE 'Proxy)) [] ]
      messageInstanceDec = InstanceD Nothing [] (ConT ''Message `AppT` ConT dat)
        [ TySynInstD ''M (TySynEqn [ ConT dat ] message) ]
  return [dataDec,proxyFunTy,proxyFunDec,messageInstanceDec]
#endif

-- This works with the type of requests produced by `mkRequest`
remote :: ( Request rqTy
          , Req rqTy ~ (Int,request)
          , ToJSON request
          , Rsp rqTy ~ response
          , FromJSON response
          , (rqTy Export.∈ rqs) ~ 'True
          )
       => FullAPI msgs rqs
       -> WebSocket
       -> Proxy rqTy
       -> request
       -> (response -> IO ())
       -> IO ()
remote api ws p rq f = do
  u <- hashUnique <$> newUnique
  void $ forkIO $ void $ do
    Export.apiRequest api ws p (u,rq) $ \_ rsp -> do
      traverse_ f rsp

-- This works with the type of requests produced by `mkRequest`
-- and conveniently prints the time the request took as well as
-- the request data and the response date.
remoteDebug :: ( Request rqTy
               , Req rqTy ~ (Int,request)
               , ToJSON request
               , ToJSON response
               , Rsp rqTy ~ response
               , FromJSON response
               , (rqTy Export.∈ rqs) ~ 'True
               )
            => FullAPI msgs rqs
            -> Export.WebSocket
            -> Proxy rqTy
            -> request
            -> (response -> IO ())
            -> IO ()
remoteDebug api ws p rq f = do
  u   <- hashUnique <$> newUnique
  u'  <- hashUnique <$> newUnique
  void $ forkIO $ void $ do
    s <- time
    Export.apiRequest api ws p (u,rq) $ \_ rsp -> do
      e <- time
      logJSON (rq,rsp,e - s)
      traverse_ f rsp

notify :: ( Message msgTy
          , M msgTy ~ message
          , ToJSON message
          , (msgTy Export.∈ msgs) ~ 'True
          )
       => FullAPI msgs rqs
       -> WebSocket
       -> Proxy msgTy
       -> message
       -> IO ()
notify api ws p msg =
  void $ forkIO $ void $ Export.apiMessage api ws p msg

#ifdef __GHCJS__
type Responding request response = ReaderT (request,IO (),Either Txt response -> IO ()) IO
#else
type Responding request response = ReaderT (request,IO (),Either LazyByteString response -> IO ()) IO
#endif

req :: Responding request response request
req = do
  (req,_,_) <- R.ask
  return req

done :: Responding request response ()
done = do
    (_,d,_) <- R.ask
    lift d

reply :: response -> Responding request response ()
reply rsp = do
    (_,_,s) <- R.ask
    lift (s $ Right rsp)

handle :: forall rqTy request response.
              ( Request rqTy
              , Req rqTy ~ (Int,request)
              , Identify (Req rqTy)
              , I (Req rqTy) ~ Int
              , FromJSON request
              , Rsp rqTy ~ response
              , ToJSON response
              )
           => Responding request response () -> RequestHandler rqTy
handle rspndng = responds (Proxy @ rqTy) $ \done -> \case
    Left dsp           -> return ()
    Right (rsp,(_,rq)) -> runReaderT rspndng (rq,done,void . rsp)

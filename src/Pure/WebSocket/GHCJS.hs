{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE UnliftedFFITypes #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE LambdaCase #-}
module Pure.WebSocket.GHCJS where

-- from pure-json
import Pure.Data.JSON as AE

-- from pure-lifted
import Pure.Data.Lifted

-- from pure-txt
import Pure.Data.Txt (Txt,ToTxt(..),FromTxt(..))

-- from pure-websocket (local)
import Pure.WebSocket.API
import Pure.WebSocket.Callbacks
import Pure.WebSocket.Dispatch
import Pure.WebSocket.Endpoint
import Pure.WebSocket.Identify
import Pure.WebSocket.Message
import Pure.WebSocket.TypeRep
import Pure.WebSocket.Request

-- from bytestring
import qualified Data.ByteString.Lazy as BSL

-- from ghcjs-base
import qualified GHCJS.Foreign.Callback as CB
import qualified GHCJS.Buffer as GB
import qualified GHCJS.Marshal as M
import qualified GHCJS.Marshal.Pure as M
import qualified JavaScript.Object.Internal as OI
import qualified GHCJS.Types as T
import qualified Data.JSString as JS (uncons)
import qualified JavaScript.TypedArray.ArrayBuffer as TAB
import qualified JavaScript.Web.MessageEvent as WME

-- from base
import Control.Concurrent
import Control.Monad
import Data.Data
import Data.Int
import Data.IORef
import Data.Foldable (for_)
import Data.List as List
import Data.Maybe
import Data.Monoid
import GHC.Generics
import Text.Read hiding (lift,get)
import Unsafe.Coerce

-- from unordered-containers
import qualified Data.HashMap.Strict as Map

type LazyByteString = BSL.ByteString

#ifdef __GHCJS__
foreign import javascript unsafe
  "$r = JSON.parse($1);" jsonParse :: Txt -> IO T.JSVal

foreign import javascript unsafe
  "$r = JSON.stringify($1);" jsonEncode :: T.JSVal -> IO Txt
#endif

type CB = CB.Callback (JSV -> IO ())

data WebSocket_
  = WebSocket
    { wsSocket            :: Maybe (JSV,CB,CB,CB,CB)
    , wsDispatchCallbacks :: !(Map.HashMap Txt [IORef (Dispatch -> IO ())])
    , wsStatus            :: Status
    , wsStatusCallbacks   :: ![IORef (Status -> IO ())]
    }

type WebSocket = IORef WebSocket_

type RequestCallback request response = IO () -> Either Dispatch (Either Txt response -> IO (Either Status SendStatus),request) -> IO ()

-- | Construct a status callback. This is a low-level method.
onStatus :: WebSocket -> (Status -> IO ()) -> IO StatusCallback
onStatus ws_ f = do
  cb <- newIORef f
  atomicModifyIORef' ws_ $ \ws -> (ws { wsStatusCallbacks = wsStatusCallbacks ws ++ [cb] },())
  return $ StatusCallback cb $
    atomicModifyIORef' ws_ $ \ws -> (ws { wsStatusCallbacks = List.filter (/= cb) (wsStatusCallbacks ws) },())

-- | Set status and call status callbacks.
setStatus :: WebSocket -> Status  -> IO ()
setStatus ws_ s = do
  cbs <- atomicModifyIORef' ws_ $ \ws -> (ws { wsStatus = s },wsStatusCallbacks ws)
  for_ cbs $ \cb_ -> do
    cb <- readIORef cb_
    cb s

-- | Construct a dispatch callback. This is a low-level method.
onDispatch :: WebSocket -> Txt -> (Dispatch -> IO ()) -> IO DispatchCallback
onDispatch ws_ hdr f = do
  cb <- newIORef f
  atomicModifyIORef' ws_ $ \ws -> (ws { wsDispatchCallbacks = Map.insertWith (flip (++)) hdr [cb] (wsDispatchCallbacks ws) },())
  return $ DispatchCallback cb $
    atomicModifyIORef' ws_ $ \ws -> (ws { wsDispatchCallbacks = Map.adjust (List.filter (/= cb)) hdr (wsDispatchCallbacks ws) },())

-- | Initialize a websocket without connecting.
websocket :: IO WebSocket
websocket = do
  newIORef WebSocket
    { wsSocket            = Nothing
    , wsDispatchCallbacks = Map.empty
    , wsStatus            = Unopened
    , wsStatusCallbacks   = []
    }

newWS :: String -> Int -> Bool -> IO WebSocket
newWS host port secure = do
  ws <- websocket
  connectWithExponentialBackoff ws 0
  return ws
  where
    connectWithExponentialBackoff ws_ n = do
      let interval = 50000
      msock <- tryNewWebSocket (toTxt $ (if secure then "wss://" else "ws://") ++ host ++ ':': show port)
      case msock of
        Nothing -> do
          setStatus ws_ Connecting
          void $ forkIO $ do
            i <- random (interval * (2 ^ n - 1))
            threadDelay i
            connectWithExponentialBackoff ws_ (min (n + 1) 12) -- ~ 200 second max interval; average max interval 100 seconds
        Just sock -> do
          openCallback <- CB.syncCallback1 CB.ContinueAsync $ \_ ->
            setStatus ws_ Opened
          addEventListener sock "open" openCallback False

          closeCallback <- CB.syncCallback1 CB.ContinueAsync $ \_ ->
            setStatus ws_ (Closed UnexpectedClosure)
          addEventListener sock "close" closeCallback False

          errorCallback <- CB.syncCallback1 CB.ContinueAsync $ \err -> do
            setStatus ws_ (Closed UnexpectedClosure)
          addEventListener sock "error" errorCallback False

          messageCallback <- CB.syncCallback1 CB.ContinueAsync $ \ev -> do
            case WME.getData $ unsafeCoerce ev of
              WME.StringData sd -> do
#if defined(DEBUGWS) || defined(DEVEL)
                putStrLn $ "Received message: " ++ show sd
#endif
                case fromJSON (js_JSON_parse sd) of
                  Error e -> putStrLn $ "fromJSON failed with: " ++ e
                  Success m -> do
                    ws <- readIORef ws_
                    case Map.lookup (ep m) (wsDispatchCallbacks ws) of
                      Nothing   -> putStrLn $ "No handler found: " ++ show (ep m)
                      Just dcbs -> do
#if defined(DEBUGWS) || defined(DEVEL)
                        putStrLn $ "Handled message at endpoint: " ++ show (ep m)
#endif
                        for_ dcbs (readIORef >=> ($ m))

              _ -> return ()

          addEventListener sock "message" messageCallback False

          modifyIORef ws_ $ \ws -> ws
            { wsSocket = Just (sock,openCallback,closeCallback,errorCallback,messageCallback) }

clientWS :: String -> Int -> IO WebSocket
clientWS h p = newWS h p False

clientWSS :: String -> Int -> IO WebSocket
clientWSS h p = newWS h p True

foreign import javascript unsafe
  "try { $r = new window[\"WebSocket\"]($1) } catch (e) { $r = null}"
    js_tryNewWebSocket :: Txt -> IO JSV

tryNewWebSocket :: Txt -> IO (Maybe JSV)
tryNewWebSocket url = do
  ws <- js_tryNewWebSocket url
  if isNull ws
    then return Nothing
    else return (Just ws)

foreign import javascript unsafe
  "$1.close()" ws_close_js :: JSV -> Int -> Txt -> IO ()

close :: WebSocket -> CloseReason -> IO ()
close ws_ cr = do
  ws <- readIORef ws_
  forM_ (wsSocket ws) $ \(sock,o,c,e,m) -> do
    ws_close_js sock 1000 "closed"
    CB.releaseCallback o
    CB.releaseCallback c
    CB.releaseCallback e
    CB.releaseCallback m
    writeIORef ws_ ws { wsSocket = Nothing }
  setStatus ws_ (Closed cr)

send' :: WebSocket -> Either Txt Dispatch -> IO (Either Status SendStatus)
send' ws_ m = go True
  where
    go b = do
      ws <- readIORef ws_
      case wsStatus ws of
        Opened ->
          case wsSocket ws of
            Just (ws,_,_,_,_) -> do
#if defined(DEBUGWS) || defined(DEVEL)
              putStrLn $ "send' sending: " ++ show (fmap pretty v)
#endif
              send_js ws (either id (encode . toJSON) m)
              return (Right Sent)
        _ -> do
          cb <- newIORef undefined
          st <- onStatus ws_ $ \case
            Opened -> do
#if defined(DEBUGWS) || defined(DEVEL)
              liftIO $ putStrLn $ "send' sending after websocket state changed: " ++ show (fmap pretty m)
#endif
              send' ws_ m
              readIORef cb >>= scCleanup
            _ -> return ()
          writeIORef cb st
          return (Right Buffered)

data SendStatus = Buffered | Sent

foreign import javascript unsafe
  "$1.send($2);" send_js :: JSV -> Txt -> IO ()

foreign import javascript unsafe
  "Math.floor((Math.random() * $1) + 1)" random :: Int -> IO Int

send :: (ToJSON a) => WebSocket -> Txt -> a -> IO (Either Status SendStatus)
send ws_ h = send' ws_ . Right . Dispatch h . toJSON

request :: ( Request rqTy
           , Req rqTy ~ request
           , ToJSON request
           , Identify request
           , I request ~ rqI
           , Rsp rqTy ~ rsp
           , FromJSON rsp
           )
         => WebSocket
         -> Proxy rqTy
         -> request
         -> (IO () -> Either Dispatch rsp -> IO ())
         -> IO DispatchCallback
request ws_ rqty_proxy req f = do
  s_ <- newIORef undefined
  let rspHdr = responseHeader rqty_proxy req
      reqHdr = requestHeader rqty_proxy
      bhvr m = f (readIORef s_ >>= dcCleanup) (maybe (Left m) Right (decodeDispatch m))
  dpc <- onDispatch ws_ rspHdr bhvr
  writeIORef s_ dpc
  send ws_ reqHdr req
  return dpc

apiRequest :: ( Request rqTy
              , Req rqTy ~ request
              , ToJSON request
              , Identify request
              , I request ~ rqI
              , Rsp rqTy ~ rsp
              , FromJSON rsp
              , (rqTy ∈ rqs) ~ 'True
              )
          => FullAPI msgs rqs
          -> WebSocket
          -> Proxy rqTy
          -> request
          -> (IO () -> Either Dispatch rsp -> IO ())
          -> IO DispatchCallback
apiRequest _ = request

respond :: ( Request rqTy
           , Req rqTy ~ request
           , Identify request
           , I request ~ rqI
           , FromJSON request
           , Rsp rqTy ~ rsp
           , ToJSON rsp
           )
        => WebSocket
        -> Proxy rqTy
        -> (IO () -> Either Dispatch (Either Txt rsp -> IO (Either Status SendStatus),request) -> IO ())
        -> IO DispatchCallback
respond ws_ rqty_proxy f = do
  s_ <- newIORef undefined
  let header = requestHeader rqty_proxy
      bhvr m = f (readIORef s_ >>= dcCleanup)
                 $ maybe (Left m) (\rq -> Right
                    (send' ws_ . fmap (encodeDispatch (responseHeader rqty_proxy rq))
                    , rq
                    )
                 ) (decodeDispatch m)
  dcb <- onDispatch ws_ header bhvr
  writeIORef s_ dcb
  return dcb

message :: ( Message mTy , M mTy ~ msg , ToJSON msg)
        => WebSocket
        -> Proxy mTy
        -> msg
        -> IO (Either Status SendStatus)
message ws_ mty_proxy = send ws_ (messageHeader mty_proxy)

apiMessage :: ( Message mTy , M mTy ~ msg , ToJSON msg , (mTy ∈ msgs) ~ 'True)
            => FullAPI msgs rqs
            -> WebSocket
            -> Proxy mTy
            -> msg
            -> IO (Either Status SendStatus)
apiMessage _ = message

onMessage :: (Message mTy, M mTy ~ msg, FromJSON msg)
          => WebSocket
          -> Proxy mTy
          -> (IO () -> Either Dispatch msg -> IO ())
          -> IO DispatchCallback
onMessage ws_ mty_proxy f = do
  s_ <- newIORef undefined
  let header = messageHeader mty_proxy
      bhvr m = f (readIORef s_ >>= dcCleanup) (maybe (Left m) Right (decodeDispatch m))
  dpc <- onDispatch ws_ header bhvr
  writeIORef s_ dpc
  return dpc

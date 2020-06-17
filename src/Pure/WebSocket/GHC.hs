{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveAnyClass #-}
module Pure.WebSocket.GHC (module Pure.WebSocket.GHC, S.SockAddr, S.Socket, WS.makeListenSocket, S.accept) where

-- from pure-json
import Pure.Data.JSON as AE

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

-- from base
import Control.Concurrent
import Control.Exception as E
import Control.Monad
import Data.Foldable (for_)
import Data.IORef
import Data.Int
import Data.List as List
import Data.Maybe
import Data.Monoid
import Data.Proxy
import Data.Ratio
import GHC.Generics
import System.IO
import System.IO.Unsafe
import Text.Read hiding (get,lift)
import Unsafe.Coerce

-- from random
import System.Random

-- from network
import qualified Network.Socket as S

-- from websockets
import           Network.WebSockets.Stream     (Stream)
import qualified Network.WebSockets.Stream     as Stream
import qualified Network.WebSockets as WS
import qualified Network.WebSockets.Stream as WS

-- from bytestring
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BL
import qualified Data.ByteString        as S
import qualified Data.ByteString.Internal as S
import qualified Data.ByteString.Unsafe as S
import qualified Data.ByteString.Lazy as BSL hiding (putStrLn)

#ifdef SECURE
-- from HsOpenSSL
import OpenSSL as SSL
import OpenSSL.Session as SSL

-- from openssl-streams
import qualified System.IO.Streams.SSL as Streams
#endif

-- from io-streams
import qualified System.IO.Streams as Streams
import qualified System.IO.Streams.Internal as Streams

-- from text
import qualified Data.Text.Lazy.Encoding as TL

-- from unordered-containers
import qualified Data.HashMap.Strict as Map

data WebSocket_
  = WebSocket
    { wsSocket            :: Maybe (S.SockAddr,S.Socket,WS.Connection,WS.Stream)
    , wsDispatchCallbacks :: !(Map.HashMap Txt [IORef (Dispatch -> IO ())])
    , wsStatus            :: Status
    , wsStatusCallbacks   :: ![IORef (Status -> IO ())]
    , wsStreamReader      :: StreamReader
    , wsStreamWriter      :: StreamWriter
    , wsConnectionOptions :: WS.ConnectionOptions
    , wsReceivers         :: [ThreadId]
    }

type StreamReader = Streams.InputStream B.ByteString -> IO (Either E.SomeException B.ByteString)
type StreamWriter = Streams.OutputStream B.ByteString -> Maybe BSL.ByteString -> IO (Maybe E.SomeException)

type WebSocket = IORef WebSocket_

type LazyByteString = BSL.ByteString

type RequestCallback request response = IO () -> Either Dispatch (Either LazyByteString response -> IO (Either Status ()),request) -> IO ()

-- | Construct a status callback. This is a low-level method.
onStatus :: WebSocket -> (Status -> IO ()) -> IO StatusCallback
onStatus ws_ f = do
  cb <- newIORef f
  modifyIORef' ws_ $ \ws -> ws
    { wsStatusCallbacks = wsStatusCallbacks ws ++ [cb]
    }
  return $ StatusCallback cb $
    modifyIORef' ws_ $ \ws -> ws
      { wsStatusCallbacks = List.filter (/= cb) (wsStatusCallbacks ws)
      }

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

defaultStreamReader :: StreamReader
defaultStreamReader = \i ->
  E.handle (return . Left)
    (maybe (Left (toException UnexpectedClosure)) Right <$> Streams.read i)

defaultStreamWriter :: StreamWriter
defaultStreamWriter = \o bs ->
  E.handle (return . Just)
    (Streams.write (fmap BL.toStrict bs) o *> pure Nothing)

-- | Initialize a websocket without connecting.
websocket :: IO WebSocket
websocket = do
  newIORef WebSocket
    { wsSocket            = Nothing
    , wsDispatchCallbacks = Map.empty
    , wsStatus            = Unopened
    , wsStatusCallbacks   = []
    , wsStreamReader      = defaultStreamReader
    , wsStreamWriter      = defaultStreamWriter
    , wsConnectionOptions = WS.defaultConnectionOptions
    , wsReceivers         = []
    }

makeStream :: WebSocket -> S.Socket -> (Streams.InputStream B.ByteString,Streams.OutputStream B.ByteString) -> IO WS.Stream
makeStream ws_ sock (i,o) = do
  sa <- S.getPeerName sock
  WS.makeStream reader' writer'
  where
    reader' = do
      rd <- wsStreamReader <$> readIORef ws_
      r <- rd i
      case r of
        Left e
          | Just e <- fromException e -> close ws_ e >> pure Nothing
          | otherwise                 -> close ws_ UnexpectedClosure >> pure Nothing
        Right bs ->
          pure (Just bs)

    writer' mbs = do
      wrt <- wsStreamWriter <$> readIORef ws_
      me <- wrt o mbs
      case me of
        Just se
          | Just e <- fromException se -> close ws_ e
          | otherwise                  -> close ws_ UnexpectedClosure
        Nothing ->
          pure ()

-- Construct a default server with unlimited reader, writer, and default websocket options without deflate.
serverWS :: S.Socket -> IO WebSocket
serverWS = serverWSWith defaultStreamReader defaultStreamWriter WS.defaultConnectionOptions

-- Construct a server websocket from an open socket with reader, writer, and websocket options.
serverWSWith :: StreamReader -> StreamWriter -> WS.ConnectionOptions -> S.Socket -> IO WebSocket
serverWSWith reader writer options sock = do
  sa <- S.getSocketName sock
  ws_ <- websocket
  modifyIORef' ws_ $ \ws -> ws
    { wsStreamReader = reader
    , wsStreamWriter = writer
    , wsConnectionOptions = options
    }
  streams <- Streams.socketToStreams sock
  wsStream <- makeStream ws_ sock streams
  pc <- WS.makePendingConnectionFromStream wsStream options
  c <- WS.acceptRequest pc
  modifyIORef' ws_ $ \ws -> ws { wsSocket = Just (sa,sock,c,wsStream), wsStatus = Opened }
  return ws_

activate :: WebSocket -> IO ()
activate ws_ = do
  ws <- readIORef ws_
  let Just (_,sock,c,_) = wsSocket ws
  rt <- forkIO $ receiveLoop sock ws_ c
  modifyIORef' ws_ $ \ws -> ws { wsReceivers = rt : wsReceivers ws }

activateGHCJS :: WebSocket -> String -> Int -> Bool -> IO ()
activateGHCJS ws _ _ _ = activate ws

clientWS :: String -> Int -> IO WebSocket
clientWS = clientWSWith defaultStreamReader defaultStreamWriter WS.defaultConnectionOptions

clientWSWith :: StreamReader -> StreamWriter -> WS.ConnectionOptions -> String -> Int -> IO WebSocket
clientWSWith reader writer options host port = do
  -- TODO: make the backoff method configurable
  ws <- websocket
  modifyIORef' ws $ \ws -> ws
    { wsStreamReader = reader
    , wsStreamWriter = writer
    , wsConnectionOptions = options
    }
  connectWithExponentialBackoff ws 5
  return ws
  where
    connectWithExponentialBackoff ws_ n = do
      let interval = 50000
      msock <- newClientSocket host port
      case msock of
        Nothing -> do
          setStatus ws_ Connecting
          void $ forkIO $ do
            gen <- newStdGen -- yuck
            let (r,_) = randomR (1,2 ^ n - 1) gen
                i = interval * r
            threadDelay i
            connectWithExponentialBackoff ws_ (min (n + 1) 8)
        Just sock -> do
          sa <- S.getPeerName sock
          streams <- Streams.socketToStreams sock
          ws <- readIORef ws_
          wsStream <- makeStream ws_ sock streams
          c <- WS.runClientWithStream wsStream host "/" (wsConnectionOptions ws) [] return
          ws <- readIORef ws_
          _ <- onStatus ws_ $ \status ->
            case status of
              Closed _ -> connectWithExponentialBackoff ws_ 5
              _        -> return ()
          rt <- forkIO $ receiveLoop sock ws_ c
          modifyIORef' ws_ $ \ws -> ws
            { wsSocket = Just (sa,sock,c,wsStream)
            , wsReceivers = rt:wsReceivers ws
            }
          setStatus ws_ Opened

#ifdef SECURE
serverWSS :: S.Socket -> SSL -> IO WebSocket
serverWSS sock ssl = serverWSSWith defaultStreamReader defaultStreamWriter WS.defaultConnectionOptions

serverWSSWith :: StreamReader -> StreamWriter -> WS.ConnectionOptions -> S.Socket -> SSL -> IO WebSocket
serverWSSWith reader writer options sock ssl = do
  sa <- S.getSocketName sock
  ws_ <- websocket
  modifyIORef' ws_ $ \ws -> ws
    { wsStreamReader = reader
    , wsStreamWriter = writer
    , wsConnectionOptions = options
    }
  streams <- Streams.sslToStreams ssl
  wsStream <- makeStream ws_ sock streams
  pc <- WS.makePendingConnectionFromStream wsStream options
  c <- WS.acceptRequest pc
  modifyIORef' ws_ $ \ws -> ws
    { wsSocket = Just (sa,sock,c,wsStream)
    , wsStatus = Opened
    }
  return ws_

clientWSS :: String -> Int -> IO WebSocket
clientWSS = clientWSSWith defaultStreamReader defaultStreamWriter WS.defaultConnectionOptions

clientWSSWith :: StreamReader -> StreamWriter -> WS.ConnectionOptions -> String -> Int -> IO WebSocket
clientWSSWith reader writer options host port = do
  ws <- websocket
  modifyIORef' ws $ \ws -> ws
    { wsStreamReader = reader
    , wsStreamWriter = writer
    , wsConnectionOptions = options
    }
  connectWithExponentialBackoff ws 0
  return ws
  where
    connectWithExponentialBackoff ws_ n = do
      let interval = 50000
      msock <- newClientSocket host port
      case msock of
        Nothing -> do
          setStatus ws_ Connecting
          forkIO $ do
            gen <- newStdGen
            let (r,_) = randomR (1,2 ^ n - 1) gen
                i = interval * r
            threadDelay i
            connectWithExponentialBackoff ws_ (min (n + 1) 12) -- ~ 200 second max interval; average max interval 100 seconds
        Just sock -> do
          sa <- S.getPeerName sock
          ssl <- sslConnect sock
          streams <- Streams.sslToStreams ssl
          ws <- readIORef ws_
          wsStream <- makeStream ws_ sock streams
          c <- WS.runClientWithStream wsStream host path (wsConnectionOptions ws) [] return
          _ <- onStatus ws_ $ \status ->
            case status of
              Closed _ -> connectWithExponentialBackoff ws_ 0
              _        -> return ()
          rt <- forkIO $ receiveLoop sock ws c
          modifyIORef' ws_ $ \ws -> ws
            { wsSocket = Just (sa,sock,c,wsStream)
            , wsReceivers = rt : wsReceivers ws
            }
          setStatus ws_ Opened
#endif

close :: WebSocket -> CloseReason -> IO ()
close ws_ cr = do
  ws <- readIORef ws_
  forM_ (wsSocket ws) $ \(sa,sock,c,s) -> do
    S.close sock
    WS.close s
    writeIORef ws_ ws
      { wsSocket = Nothing }
  setStatus ws_ (Closed cr)
  for_ (wsReceivers ws) killThread

receiveLoop sock ws_ c = go
  where
    go = do
      eem0 <- E.handle (\(_ :: WS.ConnectionException) -> return (Left (Closed InvalidMessage))) $
              Right <$> WS.receiveDataMessage c
      let eem = case eem0 of
                  Left e -> Left (Closed UnexpectedClosure)
                  Right (WS.Binary b) -> Right b
                  Right (WS.Text t _) -> Right t
#if defined(DEBUGWS) || defined(DEVEL)
      Prelude.putStrLn $ "Received websocket message: " ++ show eem
#endif
      case eem of
        Right str ->
          case eitherDecode' str of
            Left _  -> close ws_ InvalidMessage
            Right m -> do
              ws <- readIORef ws_
              case Map.lookup (ep m) (wsDispatchCallbacks ws) of
                Nothing -> do
#if defined(DEBUGWS) || defined(DEVEL)
                  Prelude.putStrLn $ "Unhandled message: " ++ show (encode m)
#endif
                  return ()
                Just cbs -> do
#if defined(DEBUGWS) || defined(DEVEL)
                  Prelude.putStrLn $ "Dispatching message: " ++ show (encode m)
#endif
                  for_ cbs (readIORef >=> ($ m))
                  go

        Left (Closed cr) -> do
#if defined(DEBUGWS) || defined(DEVEL)
          Prelude.putStrLn "Websocket is closed; receiveloop failed."
#endif
          close ws_ cr

newListenSocket :: String -> Int -> IO S.Socket
newListenSocket hn p = WS.makeListenSocket hn p

#ifdef SECURE
sslSetupServer keyFile certFile mayChainFile = do
  ctx <- SSL.context
  SSL.contextSetPrivateKeyFile ctx keyFile
  SSL.contextSetCertificateFile ctx certFile
  forM_ mayChainFile (SSL.contextSetCertificateChainFile ctx)
  SSL.contextSetCiphers ctx "HIGH"
  SSL.contextSetVerificationMode ctx VerifyNone -- VerifyPeer?
  return ctx

sslAccept conn = liftIO $ do
  ctx <- SSL.context
  ssl <- SSL.connection ctx conn
  SSL.accept ssl
  return ssl

sslConnect conn = liftIO $ do
  ctx <- SSL.context
  ssl <- SSL.connection ctx conn
  SSL.connect ssl
  return ssl
#endif

newClientSocket host port = E.handle (\(_ :: IOException) -> return Nothing) $ do
  let hints = S.defaultHints
                  { S.addrFlags = [S.AI_ADDRCONFIG, S.AI_NUMERICSERV]
                  , S.addrFamily = S.AF_INET
                  , S.addrSocketType = S.Stream
                  }
      fullHost = host ++ ":" ++ show port
  (addrInfo:_) <- S.getAddrInfo (Just hints) (Just host) (Just $ show port)
  let family = S.addrFamily addrInfo
      socketType = S.addrSocketType addrInfo
      protocol = S.addrProtocol addrInfo
      address = S.addrAddress addrInfo
  sock <- S.socket family socketType protocol
  -- S.setSocketOption sock S.NoDelay 1
  S.connect sock address
  return $ Just sock

--------------------------------------------------------------------------------
-- Custom file reading utilities

readFile8k :: FilePath -> IO LazyByteString
readFile8k = readFileN 8192

readFile16k :: FilePath -> IO LazyByteString
readFile16k = readFileN 16384

readFileN :: Int -> FilePath -> IO LazyByteString
readFileN chk f = openBinaryFile f ReadMode >>= hGetContentsN chk

hGetContentsN :: Int -> Handle -> IO LazyByteString
hGetContentsN chk h = streamRead
  where
    streamRead = unsafeInterleaveIO loop

    loop = do
        c <- S.hGetSome h chk
        if S.null c
          then hClose h >> return BL.Empty
          else do cs <- streamRead
                  return (BL.Chunk c cs)

--------------------------------------------------------------------------------
-- Raw byte-level websocket access

sendRaw :: WebSocket -> LazyByteString -> IO (Either Status ())
sendRaw ws_ b = do
  WebSocket {..} <- readIORef ws_
  case wsSocket of
    Just (_,_,c,_) -> do
#if defined(DEBUGWS) || defined(DEVEL)
      Prelude.putStrLn $ "sending: " ++ show b
#endif
      eum <- E.handle (\(e :: IOException) -> return (Left ()))
                 (Right <$> WS.sendTextData c (TL.decodeUtf8 b))
      case eum of
        Left _ -> do
          close ws_ InvalidMessage
          return (Left (Closed InvalidMessage))
        _ -> return (Right ())
    Nothing -> return (Left wsStatus)

--------------------------------------------------------------------------------
-- Streaming Dispatch interface to websockets

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
  let header = responseHeader rqty_proxy req
      bhvr m = f (readIORef s_ >>= dcCleanup) (maybe (Left m) Right (decodeDispatch m))
  dpc <- onDispatch ws_ header bhvr
  writeIORef s_ dpc
  sendRaw ws_ $ encodeBS $ encodeDispatch (requestHeader rqty_proxy) req
  return dpc

apiRequest :: ( Request rqTy
              , Req rqTy ~ request
              , ToJSON request
              , Identify request
              , I request ~ rqI
              , Rsp rqTy ~ response
              , FromJSON response
              , (rqTy ∈ rqs) ~ 'True
              )
           => API msgs rqs
           -> WebSocket
           -> Proxy rqTy
           -> request
           -> (IO () -> Either Dispatch response -> IO ())
           -> IO DispatchCallback
apiRequest _ = request

respond :: ( Request rqTy
           , Req rqTy ~ request
           , Identify request
           , I request ~ rqI
           , FromJSON request
           , Rsp rqTy ~ response
           , ToJSON response
           )
        => WebSocket
        -> Proxy rqTy
        -> (IO () -> Either Dispatch (Either LazyByteString response -> IO (Either Status ()),request) -> IO ())
        -> IO DispatchCallback
respond ws_ rqty_proxy f = do
  s_ <- newIORef undefined
  let header = requestHeader rqty_proxy
      bhvr m = f (readIORef s_ >>= dcCleanup)
                 $ maybe (Left m) (\rq -> Right
                    (sendRaw ws_ . either (buildEncodedDispatchByteString (responseHeader rqty_proxy rq)) (encodeBS . encodeDispatch (responseHeader rqty_proxy rq))
                    , rq
                    )
                 ) (decodeDispatch m)
  dcb <- onDispatch ws_ header bhvr
  writeIORef s_ dcb
  return dcb

message :: ( Message mTy , M mTy ~ msg , ToJSON msg )
        => WebSocket
        -> Proxy mTy
        -> msg
        -> IO (Either Status ())
message ws_ mty_proxy m =
  sendRaw ws_ $ encodeBS $ encodeDispatch (messageHeader mty_proxy) m

apiMessage :: ( Message mTy , M mTy ~ msg , ToJSON msg , (mTy ∈ msgs) ~ 'True )
           => API msgs rqs
           -> WebSocket
           -> Proxy mTy
           -> msg
           -> IO (Either Status ())
apiMessage _ = message

onMessage :: ( Message mTy
             , M mTy ~ msg
             , FromJSON msg
             )
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

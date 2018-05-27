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
module Pure.WebSocket.GHC (module Pure.WebSocket.GHC, S.SockAddr) where

-- from pure-json
import Pure.Data.JSON as AE

-- from pure-txt
import Pure.Txt (Txt,ToTxt(..),FromTxt(..))

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
import Data.IORef
import Data.Int
import Data.Maybe
import Data.Monoid
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
    , wsReceiver          :: Maybe ThreadId
    , wsDispatchCallbacks :: !(Map.HashMap Txt [IORef (Dispatch -> IO ())])
    , wsStatus            :: WSStatus
    , wsStatusCallbacks   :: ![IORef (Status -> IO ())]
    , wsBytesReadLimits   :: IORef (Int64,Int64)
    }

type WebSocket = IORef WebSocket_

type LazyByteString = BSL.ByteString

type RequestCallback request response = IO () -> Either Dispatch (Either LazyByteString response -> IO (Either Status ()),request) -> IO ()

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
  atomicModifyIORef' ws_ $ \ws -> (ws { wsDispatchCallbacks = Map.insertWith (flip (++)) hdr [(dcid,f)] (wsDispatchCallbacks ws) },())
  return $ DispatchCallback cb $
    atomicModifyIORef' ws_ $ \ws -> (ws { wsDispatchCallbacks = Map.adjust (List.filter (/= cb)) hdr (wsDispatchCallbacks ws) },())

-- | Initialize a websocket without connecting.
websocket :: IO WebSocket
websocket tp = do
  brl <- newIORef (8 * 1024 * 1024, 8 * 1024 * 1024) -- 2 Mib
  newIORef WebSocket
    { wsSocket            = Nothing
    , wsReceiveThread     = Nothing
    , wsDispatchCallbacks = Map.empty
    , wsStatus            = Unopened
    , wsStatusCallbacks   = []
    , wsBytesReadLimits   = brl
    }

makeExhaustible :: IORef (Int64,Int64)
                -> WebSocket
                -> S.Socket
                -> (Streams.InputStream B.ByteString,Streams.OutputStream B.ByteString)
                -> IO WS.Stream
makeExhaustible readCount ws_ sock (i,o) = do
  sa <- S.getPeerName sock
  i' <- limit sa i
  stream <- WS.makeStream
    (Streams.read i')
    (\b -> Streams.write (BL.toStrict <$> b) o)
  return stream
  where

    {-# INLINE limit #-}
    limit sa i = return $! Streams.InputStream prod pb
      where

        {-# INLINE prod #-}
        prod = (>>=) (Streams.read i) $ maybe (return Nothing) $ \x -> do
          (count,kill) <- atomicModifyIORef' readCount $ \(remaining,total) ->
            let !remaining' = remaining - fromIntegral (B.length x)
                !res = if remaining' < 0 then ((0,total),(total,True)) else ((remaining',total),(total,False))
            in res
          when kill $ close ws_ MessageLengthExceeded
          return (Just x)

        {-# INLINE pb #-}
        pb s = do
          atomicModifyIORef' readCount $ \(remaining,total) ->
            let !remaining' = remaining + fromIntegral (B.length s)
            in ((remaining',total),())
          Streams.unRead s i

-- Construct a server websocket from an open socket.
serverWS :: S.Socket -> IO WebSocket
serverWS sock = liftIO $ do
  sa <- S.getSocketName sock
  ws_ <- websocket

  brr <- wsBytesReadLimits <$> readIORef ws_
  writeIORef brr (maxBound,maxBound)

  streams <- Streams.socketToStreams sock

  wsStream <- makeExhaustible brr ws_ sock streams

  pc <- WS.makePendingConnectionFromStream
          wsStream
          WS.defaultConnectionOptions
            { WS.connectionStrictUnicode = True
            , WS.connectionCompressionOptions = WS.PermessageDeflateCompression WS.defaultPermessageDeflate
            }

  c <- WS.acceptRequest pc

  rt <- forkIO $ receiveLoop sock ws_ brr c

  modifyIORef' ws_ $ \ws -> ws { wsSocket = Just (sa,sock,c,wsStream), wsReceiveThread = Just rt, wsStatus = Opened }
  return ws_

clientWS :: String -> Int -> IO WebSocket
clientWS host port = do
  ws <- websocket
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
          streams <- Streams.socketToStreams sock
          ws <- readIORef ws_
          wsStream <- makeExhaustible (wsBytesReadLimits ws) ws_ sock streams
          c <- WS.runClientWithStream wsStream host "/" WS.defaultConnectionOptions [] return
          _ <- onStatus ws_ $ \status ->
            case status of
              Closed _ -> connectWithExponentialBackoff ws_ 0
              _        -> return ()
          rt <- forkIO $ receiveLoop sock ws wsBytesReadRef c
          modifyIORef ws_ $ \ws -> ws { wsSocket = Just (sa,sock,c,wsStream), wsReceiveThread = Just rt }
          setStatus ws_ Opened
          return ws_

#ifdef SECURE
serverWSS :: S.Socket -> SSL -> IO WebSocket
serverWSS sock ssl = do
  sa <- S.getSocketName sock
  ws_ <- websocket

  brr <- wsBytesReadLimits <$> readIORef ws_
  writeIORef brr (2 * 1024 * 1024,2 * 1024 * 1024) -- 2Mib

  streams <- Streams.sslToStreams ssl

  wsStream <- makeExhaustible brr ws_ sock streams

  pc <- WS.makePendingConnectionFromStream
          wsStream
          WS.defaultConnectionOptions

  c <- WS.acceptRequest pc

  rt <- forkIO $ receiveLoop sock ws_ brr c

  modifyIORef' ws_ $ \ws -> ws { wsSocket = Just (sa,sock,c,wsStream), wsReceiveThread = Just rt, wsStatus = Opened }
  return ws_

clientWSS :: String -> Int -> IO WebSocket
clientWSS host port = do
  ws <- websocket
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
          ssl <- liftIO $ sslConnect sock
          streams <- liftIO $ Streams.sslToStreams ssl
          ws <- readIORef ws_
          wsStream <- makeExhaustible (wsBytesReadLimits ws) ws_ sock streams
          c <- WS.runClientWithStream wsStream host path WS.defaultConnectionOptions [] return
          _ <- onStatus ws_ $ \status ->
            case status of
              Closed _ -> connectWithExponentialBackoff ws_ 0
              _        -> return ()
          rt <- forkIO $ receiveLoop sock ws wsBytesReadRef c
          modifyIORef ws_ $ \ws -> ws { wsSocket = Just (sa,sock,c,wsStream), wsReceiveThread = Just rt }
          setStatus ws_ Opened
#endif

close :: WebSocket -> CloseReason -> IO ()
close ws_ cr = do
  ws <- readIORef ws_
  forM_ (wsSocket ws) $ \(sa,sock,c,s) -> do
    S.close sock
    WS.close s
    writeIORef ws_ ws { wsSocket = Nothing }
    for_ wsReceiveThread killThread
  setStatus ws_ (Closed cr)
    -- liftIO $ E.handle (\(e :: SomeException) -> print e >> return ()) $
    --   WS.sendClose c (BLC.pack "closed")
    -- liftIO $ E.handle (\(e :: SomeException) -> print e >> return ()) $
    --   S.sClose sock

-- I hate throwing exceptions, but maybe I should here....
receiveLoop sock ws_ brr_ c = go
  where
    go = do
      eem <- E.handle (\(_ :: WS.ConnectionException) -> return (Left (Closed InvalidMessage))) $
              Right <$> WS.receiveDataMessage c
      case eem of
        Left e -> return (Left (Closed UnexpectedClosure))
        Right (WS.Binary b) -> return $ Right b
        Right (WS.Text t _) -> return $ Right t
#if defined(DEBUGWS) || defined(DEVEL)
      Prelude.putStrLn $ "Received websocket message: " ++ show eem
#endif
      case eem of
        Right str -> do
          case eitherDecode' str of
            Left _  -> close ws_ InvalidMessage
            Right m -> dispatch m >> go
              ws <- readIORef ws_
              case Map.lookup h wsDispatchCallbacks of
                Nothing -> do
#if defined(DEBUGWS) || defined(DEVEL)
                  Prelude.putStrLn $ "Unhandled message: " ++ show (encode m)
#endif
                  return ()
                Just cbs -> do
#if defined(DEBUGWS) || defined(DEVEL)
                  Prelude.putStrLn $ "Dispatching message: " ++ show (encode m)
#endif
                  for_ cbs ($ m)
                  go

        Left (Closed cr) -> do
#if defined(DEBUGWS) || defined(DEVEL)
          Prelude.putStrLn "Websocket is closed; receiveloop failed."
#endif
          close ws_ cr

resetBytesReadRef brr_ = atomicModifyIORef' brr_ $ \(_,tot) -> ((tot,tot),())

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
          close ws_ InvalidMesage
          return (Closed InvalidMessage)
        _      -> return ()
      return ewssu
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
  sendRaw ws_ $ encode $ encodeDispatch (requestHeader rqty_proxy) req
  return dpc

apiRequest :: ( Req rqTy ~ request
              , ToJSON request
              , Identify request
              , I request ~ rqI
              , Rsp rqTy ~ response
              , FromJSON response
              , (rqTy ∈ rqs) ~ 'True
              )
           => FullAPI msgs rqs
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
        => Proxy rqTy
        -> (IO () -> Either Dispatch (Either LazyByteString response -> IO (Either WSStatus ()),request) -> IO ())
        -> IO DispatchCallback
respond ws_ rqty_proxy f = do
  let header = requestHeader rqty_proxy
      bhvr m = f (readIORef s_ >>= dcCleanup)
                 $ maybe (Left m) (\rq -> Right
                    (sendRaw . either id (encode . encodeDispatch (responseHeader rqty_proxy rq))
                    , rq
                    )
                 ) (decodeDispatch m)
  onDispatch ws_ header bhvr

message :: ( MonadIO c
           , ms <: '[State () WebSocket]
           , Message mTy
           , M mTy ~ msg
           , ToJSON msg
           )
        => WebSocket
        -> Proxy mTy
        -> msg
        -> IO (Either Status ())
message ws_ mty_proxy m =
  sendRaw ws_ $ encode $ encodeDispatch (messageHeader mty_proxy) m

apiMessage :: ( Message mTy
              , M mTy ~ msg
              , ToJSON msg
              , (mTy ∈ msgs) ~ 'True
              )
           => FullAPI msgs rqs
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

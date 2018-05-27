module Pure.WebSocket.Callbacks where

-- from base
import Data.IORef

-- from pure-websocket (local)
import Pure.WebSocket.Dispatch

data CloseReason = MessageLengthExceeded | InvalidMessage | UnexpectedClosure
  deriving (Eq,Show)

data Status = Unopened | Closed CloseReason | Opened | Connecting
  deriving (Eq,Show)

data DispatchCallback = DispatchCallback
  { dcRef :: IORef (Dispatch -> IO ())
  , dcCleanup :: IO ()
  }
instance Eq DispatchCallback where
  (==) (DispatchCallback dcr1 _) (DispatchCallback dcr2 _) = dcr1 == dcr2

data StatusCallback = StatusCallback
  { scRef :: IORef (Status -> IO ())
  , scCleanup :: IO ()
  }
instance Eq StatusCallback where
  (==) (StatusCallback scr1 _) (StatusCallback scr2 _) = scr1 == scr2


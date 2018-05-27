{-# language CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module Pure.WebSocket.Dispatch where

-- from base
import GHC.Generics

-- from pure-json
import Pure.Data.JSON

-- from pure-txt
import Pure.Data.Txt (Txt)

#if defined(DEBUGAPI) || defined(DEVEL)
import Debug.Trace
#endif

data Dispatch
  = Dispatch
    { ep :: Txt
    , pl :: Value
    } deriving (Generic,ToJSON,FromJSON)

{-# INLINE encodeDispatch #-}
encodeDispatch :: ToJSON a => Txt -> a -> Dispatch
encodeDispatch ep a =
  let pl = toJSON a
  in Dispatch {..}

{-# INLINE decodeDispatch #-}
decodeDispatch :: FromJSON a => Dispatch -> Maybe a
decodeDispatch d@Dispatch {..} =
  case fromJSON pl of
    Error err ->
#if defined(DEBUGAPI) || defined(DEVEL)
      traceShow ("decodeDispatch:fromJSON => Error",err,pretty d) Nothing
#else
      Nothing
#endif
    Success a -> Just a

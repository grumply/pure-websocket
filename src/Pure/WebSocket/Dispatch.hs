{-# language CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Pure.WebSocket.Dispatch where

-- from base
import Data.Monoid
import GHC.Generics

-- from pure-json
import Pure.Data.JSON

-- from pure-txt
import Pure.Data.Txt (Txt,FromTxt(..))

-- from bytestring
import Data.ByteString.Lazy.Char8 as BSLC

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

{-# INLINE buildEncodedDispatchByteString #-}
buildEncodedDispatchByteString :: Txt -> BSLC.ByteString -> BSLC.ByteString
buildEncodedDispatchByteString (fromTxt -> ep) pl = "{\"ep\": \"" <> ep <> "\",\"pl\":" <> pl <> "}"

{-# INLINE buildEncodedDispatchTxt #-}
buildEncodedDispatchTxt :: Txt -> Txt -> Txt
buildEncodedDispatchTxt ep pl = "{\"ep\": \"" <> ep <> "\",\"pl\":" <> pl <> "}"

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

{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Pure.WebSocket.TypeRep where

import Data.Typeable
import Data.Monoid
import Data.List as L

import Pure.Data.Txt as Txt (Txt,ToTxt(..),FromTxt(..),intercalate)

-- simple textual type rep - covers most use-cases and leaves endpoints
-- available for simpler external availability.
{-# INLINE rep #-}
rep :: (Typeable p) => Proxy p -> Txt
rep p = go (typeRep p)
  where
    go tr =
      let tc = toTxt (show (typeRepTyCon tr))
          trs = typeRepArgs tr
      in Txt.intercalate " " (tc : fmap go trs)

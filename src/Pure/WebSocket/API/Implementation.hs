{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverlappingInstances #-}
module Pure.WebSocket.API.Implementation where

-- from base
import Data.Proxy

-- from pure-websocket (local)
import Pure.WebSocket.Endpoint
import Pure.WebSocket.API.Interface

data Endpoints (hndlr :: * -> *) (es :: [*])
  where
    EndpointsNull
      :: Endpoints hndlr '[]

    EndpointsCons
      :: hndlr e
      -> Endpoints hndlr es
      -> Endpoints hndlr (e ': es)

instance EmptyDefault (Endpoints hndlr) where
  none = EndpointsNull

instance EmptyDefault (API f) where
  none = APINull

instance Build (hndlr :: * -> *) (Endpoints hndlr :: [*] -> *) where
  (<:>) = EndpointsCons

instance ( Removed (y ': ys) x ~ (y ': ys)
         , Appended (x ': xs) (y ': ys) ~ (x ': zs)
         , TListAppend (Endpoints hndlr) xs (y ': ys) zs
         )
    => TListAppend (Endpoints hndlr) (x ': xs) (y ': ys) (x ': zs)
  where
    (<+++>) (EndpointsCons x xs) ys = EndpointsCons x (xs <+++> ys)


-- instance es ~ (e ': xs)
class GetHandler' (hndlr :: * -> *) (e :: *) (es :: [*]) (n :: Nat) where
  getHandler' :: Index n -> Endpoints hndlr es -> hndlr e

instance {-# OVERLAPPING #-} GetHandler' hndlr e (e ': xs) 'Z where
    getHandler' _ (EndpointsCons h _) = h

instance {-# OVERLAPPABLE #-}
         ( index ~ Offset es e
         , GetHandler' hndlr e es index
         )
    => GetHandler' hndlr e (x ': es) ('S n)
  where
    getHandler' _ (EndpointsCons _ es) =
      let index = Index :: Index index
      in getHandler' index es

class GetHandler hndlr e es where
  getHandler :: Endpoints hndlr es
             -> hndlr e

instance ( index ~ Offset es e
         , GetHandler' hndlr e es index
         )
    => GetHandler hndlr e es
  where
    getHandler es =
      let index = Index :: Index index
      in getHandler' index es

class (Removed es e ~ es')
    => DeleteHandler hndlr e es es'
  where
    deleteHandler :: Proxy e
                  -> Endpoints hndlr es
                  -> Endpoints hndlr es'

instance {-# OVERLAPPING #-}
         (Removed (e ': es) e ~ es)
    => DeleteHandler hndlr e (e ': es) es
  where
  deleteHandler _ (EndpointsCons _ hs) = hs

instance {-# OVERLAPPABLE #-}
         ( DeleteHandler hndlr e es es''
         , Removed (x ': es) e ~ es'
         , es' ~ (x ': es'')
         ) => DeleteHandler hndlr e (x ': es) es' where
  deleteHandler p (EndpointsCons mh mhs) = EndpointsCons mh (deleteHandler p mhs)


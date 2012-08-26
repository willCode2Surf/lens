{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Lens.Internal
-- Copyright   :  (C) 2012 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  Rank2Types
--
-- These are some of the explicit Functor instances that leak into the
-- type signatures of Control.Lens. You shouldn't need to import this
-- module directly, unless you are coming up with a whole new kind of
-- \"Family\" and need to add instances.
--
----------------------------------------------------------------------------
module Control.Lens.Internal
  (
  -- * Implementation details
    Context(..)
  , Focusing(..)
  , FocusingWith(..)
  , FocusingPlus(..)
  , FocusingOn(..)
  , FocusingErr(..), Err(..)
  , FocusingMay(..), May(..)
  , Traversed(..)
  , Sequenced(..)
  , Indexing(..), IndexingResult(..)
  , Min(..)
  , getMin
  , Max(..)
  , getMax
  , ElementOf(..)
  , ElementOfResult(..)
  , Bazaar(..), bazaar, duplicateBazaar, sell
  , Effect(..)
  , EffectRWS(..)
  -- , EffectS(..)
  , Gettable(..), Accessor(..), Effective(..), ineffective
  , Settable(..), Mutator(..)
  ) where

import Control.Applicative
import Control.Applicative.Backwards
import Control.Category
import Control.Comonad
import Control.Comonad.Store.Class
import Control.Lens.Isomorphic
import Control.Monad
import Prelude hiding ((.),id)
import Data.Functor.Compose
import Data.Functor.Identity
import Data.Monoid

-----------------------------------------------------------------------------
-- Functors
-----------------------------------------------------------------------------

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.State.StateT'
newtype Focusing m c a = Focusing { unfocusing :: m (c, a) }

instance Monad m => Functor (Focusing m c) where
  fmap f (Focusing m) = Focusing $ do
     (c, a) <- m
     return (c, f a)

instance (Monad m, Monoid c) => Applicative (Focusing m c) where
  pure a = Focusing (return (mempty, a))
  Focusing mf <*> Focusing ma = Focusing $ do
    (c, f) <- mf
    (d, a) <- ma
    return (mappend c d, f a)

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.RWS.RWST'
newtype FocusingWith w m c a = FocusingWith { unfocusingWith :: m (c, a, w) }

instance Monad m => Functor (FocusingWith w m c) where
  fmap f (FocusingWith m) = FocusingWith $ do
     (c, a, w) <- m
     return (c, f a, w)

instance (Monad m, Monoid c, Monoid w) => Applicative (FocusingWith w m c) where
  pure a = FocusingWith (return (mempty, a, mempty))
  FocusingWith mf <*> FocusingWith ma = FocusingWith $ do
    (c, f, w) <- mf
    (d, a, w') <- ma
    return (mappend c d, f a, mappend w w')

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.Writer.WriterT'.
newtype FocusingPlus w k c a = FocusingPlus { unfocusingPlus :: k (c, w) a }

instance Functor (k (c, w)) => Functor (FocusingPlus w k c) where
  fmap f (FocusingPlus as) = FocusingPlus (fmap f as)

instance (Monoid w, Applicative (k (c, w))) => Applicative (FocusingPlus w k c) where
  pure = FocusingPlus . pure
  FocusingPlus kf <*> FocusingPlus ka = FocusingPlus (kf <*> ka)

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.Trans.Maybe.MaybeT' or 'Control.Monad.Trans.List.ListT'
newtype FocusingOn f k c a = FocusingOn { unfocusingOn :: k (f c) a }

instance Functor (k (f c)) => Functor (FocusingOn f k c) where
  fmap f (FocusingOn as) = FocusingOn (fmap f as)

instance Applicative (k (f c)) => Applicative (FocusingOn f k c) where
  pure = FocusingOn . pure
  FocusingOn kf <*> FocusingOn ka = FocusingOn (kf <*> ka)

-- | Make a monoid out of 'Maybe' for error handling
newtype May a = May { getMay :: Maybe a }

instance Monoid a => Monoid (May a) where
  mempty = May (Just mempty)
  May Nothing `mappend` _ = May Nothing
  _ `mappend` May Nothing = May Nothing
  May (Just a) `mappend` May (Just b) = May (Just (mappend a b))

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.Error.ErrorT'
newtype FocusingMay k c a = FocusingMay { unfocusingMay :: k (May c) a }

instance Functor (k (May c)) => Functor (FocusingMay k c) where
  fmap f (FocusingMay as) = FocusingMay (fmap f as)

instance Applicative (k (May c)) => Applicative (FocusingMay k c) where
  pure = FocusingMay . pure
  FocusingMay kf <*> FocusingMay ka = FocusingMay (kf <*> ka)

-- | Make a monoid out of 'Either' for error handling
newtype Err e a = Err { getErr :: Either e a }

instance Monoid a => Monoid (Err e a) where
  mempty = Err (Right mempty)
  Err (Left e) `mappend` _ = Err (Left e)
  _ `mappend` Err (Left e) = Err (Left e)
  Err (Right a) `mappend` Err (Right b) = Err (Right (mappend a b))

-- | Used by 'Control.Lens.Type.Zoom' to 'Control.Lens.Type.zoom' into 'Control.Monad.Error.ErrorT'
newtype FocusingErr e k c a = FocusingErr { unfocusingErr :: k (Err e c) a }

instance Functor (k (Err e c)) => Functor (FocusingErr e k c) where
  fmap f (FocusingErr as) = FocusingErr (fmap f as)

instance Applicative (k (Err e c)) => Applicative (FocusingErr e k c) where
  pure = FocusingErr . pure
  FocusingErr kf <*> FocusingErr ka = FocusingErr (kf <*> ka)

-- | The indexed store can be used to characterize a 'Control.Lens.Type.Lens'
-- and is used by 'Control.Lens.Type.clone'
data Context c d a = Context (d -> a) c

instance Functor (Context c d) where
  fmap f (Context g c) = Context (f . g) c

instance (c ~ d) => Comonad (Context c d) where
  extract   (Context f c) = f c
  duplicate (Context f c) = Context (Context f) c
  extend g  (Context f c) = Context (g . Context f) c

instance (c ~ d) => ComonadStore c (Context c d) where
  pos (Context _ c) = c
  peek c (Context g _) = g c
  peeks f (Context g c) = g (f c)
  seek c (Context g _) = Context g c
  seeks f (Context g c) = Context g (f c)
  experiment f (Context g c) = g <$> f c

data IndexingResult f a = IndexingResult (f a) {-# UNPACK #-} !Int

instance Functor f => Functor (IndexingResult f) where
  fmap f (IndexingResult fa n) = IndexingResult (fmap f fa) n

-- | Applicative composition of @'Control.Monad.Trans.State.Lazy.State' 'Int'@ with a 'Functor', used
-- by 'Control.Lens.Indexed.indexed'
newtype Indexing f a = Indexing { runIndexing :: Int -> IndexingResult f a }

instance Functor f => Functor (Indexing f) where
  fmap f (Indexing m) = Indexing $ \i -> fmap f (m i)

instance Applicative f => Applicative (Indexing f) where
  pure = Indexing . IndexingResult . pure
  Indexing mf <*> Indexing ma = Indexing $ \i -> case mf i of
    IndexingResult ff j -> case ma j of
       IndexingResult fa k -> IndexingResult (ff <*> fa) k

-- | Used internally by 'Control.Lens.Traversal.traverseOf_' and the like.
newtype Traversed f = Traversed { getTraversed :: f () }

instance Applicative f => Monoid (Traversed f) where
  mempty = Traversed (pure ())
  Traversed ma `mappend` Traversed mb = Traversed (ma *> mb)

-- | Used internally by 'Control.Lens.Traversal.mapM_' and the like.
newtype Sequenced m = Sequenced { getSequenced :: m () }

instance Monad m => Monoid (Sequenced m) where
  mempty = Sequenced (return ())
  Sequenced ma `mappend` Sequenced mb = Sequenced (ma >> mb)

-- | Used for 'Control.Lens.Fold.minimumOf'
data Min a = NoMin | Min a

instance Ord a => Monoid (Min a) where
  mempty = NoMin
  mappend NoMin m = m
  mappend m NoMin = m
  mappend (Min a) (Min b) = Min (min a b)

-- | Obtain the minimum.
getMin :: Min a -> Maybe a
getMin NoMin   = Nothing
getMin (Min a) = Just a

-- | Used for 'Control.Lens.Fold.maximumOf'
data Max a = NoMax | Max a

instance Ord a => Monoid (Max a) where
  mempty = NoMax
  mappend NoMax m = m
  mappend m NoMax = m
  mappend (Max a) (Max b) = Max (max a b)

-- | Obtain the maximum
getMax :: Max a -> Maybe a
getMax NoMax   = Nothing
getMax (Max a) = Just a

-- | The result of trying to find the /n/th 'Control.Lens.Traversal.element' of a 'Control.Lens.Traversal.Traversal'.
data ElementOfResult f a
  = Searching {-# UNPACK #-} !Int a
  | Found {-# UNPACK #-} !Int (f a)
  | NotFound String

instance Functor f => Functor (ElementOfResult f) where
  fmap f (Searching i a) = Searching i (f a)
  fmap f (Found i as) = Found i (fmap f as)
  fmap _ (NotFound e) = NotFound e

-- | Used to find the /n/th 'Control.Lens.Traversal.element' of a 'Control.Lens.Traversal.Traversal'.
newtype ElementOf f a = ElementOf { getElementOf :: Int -> ElementOfResult f a }

instance Functor f => Functor (ElementOf f) where
  fmap f (ElementOf m) = ElementOf $ \i -> case m i of
    Searching j a -> Searching j (f a)
    Found j as    -> Found j (fmap f as)
    NotFound e    -> NotFound e

instance Functor f => Applicative (ElementOf f) where
  pure a = ElementOf $ \i -> Searching i a
  ElementOf mf <*> ElementOf ma = ElementOf $ \i -> case mf i of
    Found j ff -> case ma j of
      Found _ _     -> NotFound "multiple results"
      Searching k a -> Found k (fmap ($a) ff)
      NotFound e    -> NotFound e
    Searching j f -> case ma j of
      Found k as    -> Found k (fmap f as)
      Searching k a -> Searching k (f a)
      NotFound e    -> NotFound e
    NotFound e -> NotFound e


-- | This is used to characterize a 'Control.Lens.Traversal.Traversal'.
--
-- a.k.a. indexed Cartesian store comonad, indexed Kleene store comonad, or an indexed 'FunList'.
--
-- <http://twanvl.nl/blog/haskell/non-regular1>
--
-- Mnemonically, a 'Bazaar' holds many stores and you can easily add more.
data Bazaar c d a
  = Buy a
  | Trade (Bazaar c d (d -> a)) c

instance Functor (Bazaar c d) where
  fmap f (Buy a)    = Buy (f a)
  fmap f (Trade k b) = Trade (fmap (f .) k)  b

instance Applicative (Bazaar c d) where
  pure            = Buy
  Buy f     <*> m = fmap f m
  Trade k c <*> m = Trade (flip <$> k <*> m) c

instance (c ~ d) => Comonad (Bazaar c d) where
  extract (Buy a)     = a
  extract (Trade z c) = extract z c
  duplicate = duplicateBazaar

-- | 'Bazaar' is an indexed 'Comonad'.
duplicateBazaar :: Bazaar c e a -> Bazaar c d (Bazaar d e a)
duplicateBazaar (Buy b)     = Buy (Buy b)
duplicateBazaar (Trade z c) = Trade (Trade <$> duplicateBazaar z) c

-- | A trivial 'Bazaar'.
sell :: c -> Bazaar c d d
sell = Trade (Buy id)

instance (c ~ d) => ComonadApply (Bazaar c d) where
  (<@>) = (<*>)

-- | Given an action to run for each matched pair, traverse a bazaar.
bazaar :: Applicative f => (c -> f d) -> Bazaar c d b -> f b
bazaar _ (Buy b)    = pure b
bazaar f (Trade k c) = f c <**> bazaar f k

-- | Wrap a monadic effect with a phantom type argument.
newtype Effect m r a = Effect { getEffect :: m r }

instance Functor (Effect m r) where
  fmap _ (Effect m) = Effect m

instance (Monad m, Monoid r) => Monoid (Effect m r a) where
  mempty = Effect (return mempty)
  Effect ma `mappend` Effect mb = Effect (liftM2 mappend ma mb)

instance (Monad m, Monoid r) => Applicative (Effect m r) where
  pure _ = Effect (return mempty)
  Effect ma <*> Effect mb = Effect (liftM2 mappend ma mb)

-- | Wrap a monadic effect with a phantom type argument. Used when magnifying RWST.
newtype EffectRWS w s m c a = EffectRWS { getEffectRWS :: s -> m (c,s,w) }

instance Functor (EffectRWS w s m c) where
  fmap _ (EffectRWS m) = EffectRWS m

instance (Monoid c, Monoid w, Monad m) => Applicative (EffectRWS w s m c) where
  pure _ = EffectRWS $ \s -> return (mempty, s, mempty)
  EffectRWS m <*> EffectRWS n = EffectRWS $ \s -> m s >>= \ (c,t,w) -> n t >>= \ (c',u,w') -> return (mappend c c', u, mappend w w')

{-
-- | Wrap a monadic effect with a phantom type argument. Used when magnifying StateT.
newtype EffectS s k c a = EffectS { runEffect :: s -> k (c, s) a }

instance Functor (k (c, s)) => Functor (EffectS s m c) where
  fmap f (EffectS m) = EffectS (fmap f . m)

instance (Monoid c, Monad m) => Applicative (EffectS s m c) where
  pure _ = EffectS $ \s -> return (mempty, s)
  EffectS m <*> EffectS n = EffectS $ \s -> m s >>= \ (c,t) -> n s >>= \ (d, u) -> return (mappend c d, u)
-}

-------------------------------------------------------------------------------
-- Gettables & Accessors
-------------------------------------------------------------------------------

-- | Generalizing 'Const' so we can apply simple 'Applicative'
-- transformations to it and so we can get nicer error messages
--
-- A 'Gettable' 'Functor' ignores its argument, which it carries solely as a
-- phantom type parameter.
--
-- To ensure this, an instance of 'Gettable' is required to satisfy:
--
-- @'id' = 'fmap' f = 'coerce'@
class Functor f => Gettable f where
  -- | Replace the phantom type argument.
  coerce :: f a -> f b

instance Gettable (Const r) where
  coerce (Const m) = Const m

instance Gettable f => Gettable (Backwards f) where
  coerce = Backwards . coerce . forwards

instance (Functor f, Gettable g) => Gettable (Compose f g) where
  coerce = Compose . fmap coerce . getCompose

instance Gettable (Effect m r) where
  coerce (Effect m) = Effect m

instance Gettable (EffectRWS w s m c) where
  coerce (EffectRWS m) = EffectRWS m

--instance Gettable (EffectS s m c) where
--  coerce (EffectS m) = EffectS m

-- | This instance is a lie, but it is a useful lie.
instance Gettable f => Gettable (ElementOf f) where
  coerce (ElementOf m) = ElementOf $ \i -> case m i of
    Searching _ _ -> NotFound "coerced while searching" -- er...
    Found j as    -> Found j (coerce as)
    NotFound s    -> NotFound s

instance Gettable (Accessor r) where
  coerce (Accessor m) = Accessor m

-- | Used instead of 'Const' to report
--
-- @No instance of ('Control.Lens.Setter.Settable' 'Accessor')@
--
-- when the user attempts to misuse a 'Control.Lens.Setter.Setter' as a
-- 'Getter', rather than a monolithic unification error.
newtype Accessor r a = Accessor { runAccessor :: r }

instance Functor (Accessor r) where
  fmap _ (Accessor m) = Accessor m

instance Monoid r => Applicative (Accessor r) where
  pure _ = Accessor mempty
  Accessor a <*> Accessor b = Accessor (mappend a b)

-- | An 'Effective' 'Functor' ignores its argument and is isomorphic to a monad wrapped around a value.
--
-- That said, the monad is possibly rather unrelated to any 'Applicative' structure.
class (Monad m, Gettable f) => Effective m r f | f -> m r where
  effective :: Isomorphic k => k (m r) (f a)

-- | A convenient antonym that is used internally.
ineffective :: Effective m r f => Isomorphic k => k (f a) (m r)
ineffective = from effective
{-# INLINE ineffective #-}

instance Effective Identity r (Accessor r) where
  effective = isomorphic (Accessor . runIdentity) (Identity . runAccessor)
  {-# INLINE effective #-}
  {-# SPECIALIZE effective :: Identity r -> Accessor r a #-}
  {-# SPECIALIZE effective :: Isomorphism (Identity r) (Accessor r a) #-}

instance Effective m r f => Effective m (Dual r) (Backwards f) where
  effective = isomorphic (Backwards . effective . liftM getDual) (liftM Dual . ineffective . forwards)

instance Monad m => Effective m r (Effect m r) where
  effective = isomorphic Effect getEffect
  {-# SPECIALIZE effective :: Monad m => m r -> Effect m r a #-}
  {-# SPECIALIZE effective :: Monad m => Isomorphism (m r) (Effect m r a) #-}

-----------------------------------------------------------------------------
-- Settables & Mutators
-----------------------------------------------------------------------------

-- | Anything 'Settable' must be isomorphic to the 'Identity' 'Functor'.
class Applicative f => Settable f where
  untainted :: f a -> a

-- | so you can pass our a 'Setter' into combinators from other lens libraries
instance Settable Identity where
  untainted = runIdentity
  {-# INLINE untainted #-}

-- | 'Control.Lens.Fold.backwards'
instance Settable f => Settable (Backwards f) where
  untainted = untainted . forwards
  {-# INLINE untainted #-}

instance (Settable f, Settable g) => Settable (Compose f g) where
  untainted = untainted . untainted . getCompose
  {-# INLINE untainted #-}

instance Settable Mutator where
  untainted = runMutator
  {-# INLINE untainted #-}

-- | 'Mutator' is just a renamed 'Identity' functor to give better error
-- messages when someone attempts to use a getter as a setter.
--
-- Most user code will never need to see this type.
newtype Mutator a = Mutator { runMutator :: a }

instance Functor Mutator where
  fmap f (Mutator a) = Mutator (f a)

instance Applicative Mutator where
  pure = Mutator
  Mutator f <*> Mutator a = Mutator (f a)



{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Unsafe #-}
--------------------------------------------------------------------------------
-- |
-- Copyright   : (c) Edward Kmett 2015
-- License     : BSD-style
-- Maintainer  : Edward Kmett <ekmett@gmail.com>
-- Portability : non-portable
--
-- Small primitive boxed arrays
--
--------------------------------------------------------------------------------
module Data.Transient.Primitive.SmallArray
  ( SmallArray(..)
  , SmallMutableArray(..)
  , newSmallArray
  , readSmallArray
  , writeSmallArray
  , indexSmallArray
  , indexSmallArrayM
  , unsafeFreezeSmallArray
  , unsafeThawSmallArray
  , sameSmallMutableArray
  , copySmallArray
  , copySmallMutableArray
  , cloneSmallArray
  , cloneSmallMutableArray
  , casSmallArray
  , sizeOfSmallArray
  , sizeOfSmallMutableArray
  ) where

import Control.Applicative
import Control.DeepSeq
import Control.Lens
import Control.Monad
import Control.Monad.Primitive
import Control.Monad.Zip
import Data.Data
import Data.Foldable as Foldable
import GHC.Exts
import GHC.ST

-- | Boxed arrays
data SmallArray a = SmallArray (SmallArray# a)

-- | Mutable boxed arrays associated with a primitive state token.
data SmallMutableArray s a = SmallMutableArray (SmallMutableArray# s a)

instance Eq (SmallMutableArray s a) where
  (==) = sameSmallMutableArray

#ifndef HLINT
type role SmallMutableArray nominal representational
#endif

-- | Create a new mutable array of the specified size and initialise all
-- elements with the given value.
newSmallArray :: PrimMonad m => Int -> a -> m (SmallMutableArray (PrimState m) a)
{-# INLINE newSmallArray #-}
newSmallArray (I# n#) x = primitive
   (\s# -> case newSmallArray# n# x s# of
             (# s'#, arr# #) -> (# s'#, SmallMutableArray arr# #))

-- | Read a value from the array at the given index.
readSmallArray :: PrimMonad m => SmallMutableArray (PrimState m) a -> Int -> m a
{-# INLINE readSmallArray #-}
readSmallArray (SmallMutableArray arr#) (I# i#) = primitive (readSmallArray# arr# i#)

-- | Write a value to the array at the given index.
writeSmallArray :: PrimMonad m => SmallMutableArray (PrimState m) a -> Int -> a -> m ()
{-# INLINE writeSmallArray #-}
writeSmallArray (SmallMutableArray arr#) (I# i#) x = primitive_ (writeSmallArray# arr# i# x)

-- | Read a value from the immutable array at the given index.
indexSmallArray :: SmallArray a -> Int -> a
{-# INLINE indexSmallArray #-}
indexSmallArray (SmallArray arr#) (I# i#) = case indexSmallArray# arr# i# of (# x #) -> x

-- | Monadically read a value from the immutable array at the given index.
-- This allows us to be strict in the array while remaining lazy in the read
-- element which is very useful for collective operations. Suppose we want to
-- copy an array. We could do something like this:
--
-- > copy marr arr ... = do ...
-- >                        writeSmallArray marr i (indexSmallArray arr i) ...
-- >                        ...
--
-- But since primitive arrays are lazy, the calls to 'indexSmallArray' will not be
-- evaluated. Rather, @marr@ will be filled with thunks each of which would
-- retain a reference to @arr@. This is definitely not what we want!
--
-- With 'indexSmallArrayM', we can instead write
--
-- > copy marr arr ... = do ...
-- >                        x <- indexSmallArrayM arr i
-- >                        writeSmallArray marr i x
-- >                        ...
--
-- Now, indexing is executed immediately although the returned element is
-- still not evaluated.
--
indexSmallArrayM :: Monad m => SmallArray a -> Int -> m a
{-# INLINE indexSmallArrayM #-}
indexSmallArrayM (SmallArray arr#) (I# i#)
  = case indexSmallArray# arr# i# of (# x #) -> return x

-- | Convert a mutable array to an immutable one without copying. The
-- array should not be modified after the conversion.
unsafeFreezeSmallArray :: PrimMonad m => SmallMutableArray (PrimState m) a -> m (SmallArray a)
{-# INLINE unsafeFreezeSmallArray #-}
unsafeFreezeSmallArray (SmallMutableArray arr#)
  = primitive (\s# -> case unsafeFreezeSmallArray# arr# s# of
                        (# s'#, arr'# #) -> (# s'#, SmallArray arr'# #))

-- | Convert an immutable array to an mutable one without copying. The
-- immutable array should not be used after the conversion.
unsafeThawSmallArray :: PrimMonad m => SmallArray a -> m (SmallMutableArray (PrimState m) a)
{-# INLINE unsafeThawSmallArray #-}
unsafeThawSmallArray (SmallArray arr#)
  = primitive (\s# -> case unsafeThawSmallArray# arr# s# of
                        (# s'#, arr'# #) -> (# s'#, SmallMutableArray arr'# #))

-- | Check whether the two arrays refer to the same memory block.
sameSmallMutableArray :: SmallMutableArray s a -> SmallMutableArray s a -> Bool
{-# INLINE sameSmallMutableArray #-}
sameSmallMutableArray (SmallMutableArray arr#) (SmallMutableArray brr#)
  = isTrue# (sameSmallMutableArray# arr# brr#)

-- | Copy a slice of an immutable array to a mutable array.
copySmallArray :: PrimMonad m
          => SmallMutableArray (PrimState m) a    -- ^ destination array
          -> Int                             -- ^ offset into destination array
          -> SmallArray a                         -- ^ source array
          -> Int                             -- ^ offset into source array
          -> Int                             -- ^ number of elements to copy
          -> m ()
{-# INLINE copySmallArray #-}
copySmallArray (SmallMutableArray dst#) (I# doff#) (SmallArray src#) (I# soff#) (I# len#)
  = primitive_ (copySmallArray# src# soff# dst# doff# len#)

-- | Copy a slice of a mutable array to another array. The two arrays may
-- not be the same.
copySmallMutableArray :: PrimMonad m
          => SmallMutableArray (PrimState m) a    -- ^ destination array
          -> Int                             -- ^ offset into destination array
          -> SmallMutableArray (PrimState m) a    -- ^ source array
          -> Int                             -- ^ offset into source array
          -> Int                             -- ^ number of elements to copy
          -> m ()
{-# INLINE copySmallMutableArray #-}
copySmallMutableArray (SmallMutableArray dst#) (I# doff#)
                 (SmallMutableArray src#) (I# soff#) (I# len#)
  = primitive_ (copySmallMutableArray# src# soff# dst# doff# len#)

-- | Return a newly allocated SmallArray with the specified subrange of the
-- provided SmallArray. The provided SmallArray should contain the full subrange
-- specified by the two Ints, but this is not checked.
cloneSmallArray :: SmallArray a -- ^ source array
           -> Int     -- ^ offset into destination array
           -> Int     -- ^ number of elements to copy
           -> SmallArray a
{-# INLINE cloneSmallArray #-}
cloneSmallArray (SmallArray arr#) (I# off#) (I# len#)
  = case cloneSmallArray# arr# off# len# of arr'# -> SmallArray arr'#

-- | Return a newly allocated SmallMutableArray. with the specified subrange of
-- the provided SmallMutableArray. The provided SmallMutableArray should contain the
-- full subrange specified by the two Ints, but this is not checked.
cloneSmallMutableArray :: PrimMonad m
        => SmallMutableArray (PrimState m) a -- ^ source array
        -> Int                          -- ^ offset into destination array
        -> Int                          -- ^ number of elements to copy
        -> m (SmallMutableArray (PrimState m) a)
{-# INLINE cloneSmallMutableArray #-}
cloneSmallMutableArray (SmallMutableArray arr#) (I# off#) (I# len#) = primitive
   (\s# -> case cloneSmallMutableArray# arr# off# len# s# of
             (# s'#, arr'# #) -> (# s'#, SmallMutableArray arr'# #))

instance IsList (SmallArray a) where
  type Item (SmallArray a) = a
  toList = Foldable.toList
  fromListN n xs0 = runST $ do
    arr <- newSmallArray n undefined
    let go !_ []     = return ()
        go k (x:xs) = writeSmallArray arr k x >> go (k+1) xs
    go 0 xs0
    unsafeFreezeSmallArray arr
  fromList xs = fromListN (Prelude.length xs) xs

instance Functor SmallArray where
  fmap f !i = runST $ do
    let n = length i
    o <- newSmallArray n undefined
    let go !k
          | k == n = return ()
          | otherwise = do
            a <- indexSmallArrayM i k
            writeSmallArray o k (f a)
            go (k+1)
    go 0
    unsafeFreezeSmallArray o

instance Foldable SmallArray where
  foldr f z arr = go 0 where
    n = length arr
    go !k
      | k == n    = z
      | otherwise = f (indexSmallArray arr k) (go (k+1))

  foldl f z arr = go (length arr - 1) where
    go !k
      | k < 0 = z
      | otherwise = f (go (k-1)) (indexSmallArray arr k)

  foldr' f z arr = go 0 where
    n = length arr
    go !k
      | k == n    = z
      | r <- indexSmallArray arr k = r `seq` f r (go (k+1))

  foldl' f z arr = go (length arr - 1) where
    go !k
      | k < 0 = z
      | r <- indexSmallArray arr k = r `seq` f (go (k-1)) r

  null a = length a == 0

  length = sizeOfSmallArray
  {-# INLINE length #-}

sizeOfSmallArray :: SmallArray a -> Int
sizeOfSmallArray (SmallArray a) = I# (sizeofSmallArray# a)
{-# INLINE sizeOfSmallArray #-}

instance Traversable SmallArray where
  traverse f a = fromListN (length a) <$> traverse f (Foldable.toList a)

instance Applicative SmallArray where
  pure a = runST $ newSmallArray 1 a >>= unsafeFreezeSmallArray
  (m :: SmallArray (a -> b)) <*> (n :: SmallArray a) = runST $ do
      o <- newSmallArray (lm * ln) undefined
      outer o 0 0
    where
      lm = length m
      ln = length n
      outer :: SmallMutableArray s b -> Int -> Int -> ST s (SmallArray b)
      outer o !i p
        | i < lm = do
            f <- indexSmallArrayM m i
            inner o i 0 f p
        | otherwise = unsafeFreezeSmallArray o
      inner :: SmallMutableArray s b -> Int -> Int -> (a -> b) -> Int -> ST s (SmallArray b)
      inner o i !j f !p
        | j < ln = do
            x <- indexSmallArrayM n j
            writeSmallArray o p (f x)
            inner o i (j + 1) f (p + 1)
        | otherwise = outer o (i + 1) p

instance Monad SmallArray where
  return = pure
  (>>) = (*>)
  m >>= f = foldMap f m

instance MonadZip SmallArray where
  mzipWith (f :: a -> b -> c) m n = runST $ do
    o <- newSmallArray l undefined
    go o 0
    where
      l = min (length m) (length n)
      go :: SmallMutableArray s c -> Int -> ST s (SmallArray c)
      go o !i
        | i < l = do
          a <- indexSmallArrayM m i
          b <- indexSmallArrayM n i
          writeSmallArray o i (f a b)
          go o (i + 1)
        | otherwise = unsafeFreezeSmallArray o
  munzip m = (fmap fst m, fmap snd m)

instance MonadPlus SmallArray where
  mzero = empty
  mplus = (<|>)

instance Alternative SmallArray where
  empty = runST $ newSmallArray 0 undefined >>= unsafeFreezeSmallArray
  m@(SmallArray pm) <|> n@(SmallArray pn) = runST $ case length m of
     lm@(I# ilm) -> case length n of
       ln@(I# iln) -> do
         o@(SmallMutableArray po) <- newSmallArray (lm + ln) undefined
         primitive_ $ \s -> case copySmallArray# pm 0# po 0# ilm s of
           s' -> copySmallArray# pn 0# po ilm iln s'
         unsafeFreezeSmallArray o

instance Semigroup (SmallArray a) where
  (<>) = (<|>)

instance Monoid (SmallArray a) where
  mempty = empty

instance Show a => Show (SmallArray a) where
  showsPrec d as = showParen (d > 10) $
    showString "fromList " . showsPrec 11 (Foldable.toList as)

instance Read a => Read (SmallArray a) where
  readsPrec d = readParen (d > 10) $ \s -> [(fromList m, u) | ("fromList", t) <- lex s, (m,u) <- readsPrec 11 t]

instance Ord a => Ord (SmallArray a) where
  compare as bs = compare (Foldable.toList as) (Foldable.toList bs)

instance Eq a => Eq (SmallArray a) where
  as == bs = Foldable.toList as == Foldable.toList bs

instance NFData a => NFData (SmallArray a) where
  rnf a0 = go a0 (length a0) 0 where
    go !a !n !i
      | i >= n = ()
      | otherwise = rnf (indexSmallArray a i) `seq` go a n (i+1)
  {-# INLINE rnf #-}

instance Data a => Data (SmallArray a) where
  gfoldl f z m   = z fromList `f` Foldable.toList m
  toConstr _     = fromListConstr
  gunfold k z c  = case constrIndex c of
    1 -> k (z fromList)
    _ -> error "gunfold"
  dataTypeOf _   = smallArrayDataType
  dataCast1 f    = gcast1 f

fromListConstr :: Constr
fromListConstr = mkConstr smallArrayDataType "fromList" [] Prefix

smallArrayDataType :: DataType
smallArrayDataType = mkDataType "Data.Transient.Primitive.SmallArray.SmallArray" [fromListConstr]

-- * Lens support

type instance Index (SmallArray a) = Int
type instance IxValue (SmallArray a) = a

instance Ixed (SmallArray a) where
  ix i f m
    | 0 <= i && i < n = go <$> f (indexSmallArray m i)
    | otherwise = pure m
    where
      n = sizeOfSmallArray m
      go a = runST $ do
        o <- newSmallArray n undefined
        copySmallArray o 0 m 0 n
        writeSmallArray o i a
        unsafeFreezeSmallArray o

instance AsEmpty (SmallArray a) where
  _Empty = nearly empty null

instance Cons (SmallArray a) (SmallArray b) a b where
  _Cons = prism hither yon where
    hither (a,m) | n <- sizeOfSmallArray m = runST $ do
      o <- newSmallArray (n + 1) a
      copySmallArray o 1 m 0 n
      unsafeFreezeSmallArray o
    yon m
      | n <- sizeOfSmallArray m
      , n > 0 = Right
        ( indexSmallArray m 0
        , runST $ do
          o <- newSmallArray (n - 1) undefined
          copySmallArray o 0 m 1 (n - 1)
          unsafeFreezeSmallArray o
        )
      | otherwise = Left empty

instance Snoc (SmallArray a) (SmallArray b) a b where
  _Snoc = prism hither yon where
    hither (m,a) | n <- sizeOfSmallArray m = runST $ do
      o <- newSmallArray (n + 1) a
      copySmallArray o 0 m 0 n
      unsafeFreezeSmallArray o
    yon m
      | n <- sizeOfSmallArray m
      , n > 0 = Right
        ( runST $ do
          o <- newSmallArray (n - 1) undefined
          copySmallArray o 0 m 0 (n - 1)
          unsafeFreezeSmallArray o
        , indexSmallArray m 0
        )
      | otherwise = Left empty

--------------------------------------------------------------------------------
-- * "Evil" Small Mutable Array instances
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- * Small Mutable Array combinators
--------------------------------------------------------------------------------

sizeOfSmallMutableArray :: SmallMutableArray s a -> Int
sizeOfSmallMutableArray (SmallMutableArray a) = I# (sizeofSmallMutableArray# a)
{-# INLINE sizeOfSmallMutableArray #-}

-- | Perform an unsafe, machine-level atomic compare and swap on an element within an array.
casSmallArray :: PrimMonad m => SmallMutableArray (PrimState m) a -> Int -> a -> a -> m (Int, a)
casSmallArray (SmallMutableArray m) (I# i) a b = primitive $ \s -> case casSmallArray# m i a b s of
  (# s', j, c #) -> (# s', (I# j, c) #)

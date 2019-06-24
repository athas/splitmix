-- |
-- /SplitMix/ is a splittable pseudorandom number generator (PRNG) that is quite fast.
--
-- This is 32bit variant (original one is 32 bit).
--
-- You __really don't want to use this one__.
--
--  Note: This module supports all GHCs since GHC-7.0.4,
--  but GHC-7.0 and GHC-7.2 have slow implementation, as there
--  are no native 'popCount'.
--
{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
#if __GLASGOW_HASKELL__ >= 702
{-# LANGUAGE Trustworthy #-}
#endif
module System.Random.SplitMix32 (
    SMGen,
    nextWord32,
    nextWord64,
    nextTwoWord32,
    nextInt,
    nextDouble,
    nextFloat,
    splitSMGen,
    -- * Initialisation
    mkSMGen,
    initSMGen,
    newSMGen,
    seedSMGen,
    seedSMGen',
    unseedSMGen,
    ) where

import Control.DeepSeq       (NFData (..))
import Data.Bits             (shiftL, shiftR, xor, (.|.))
import Data.IORef            (IORef, atomicModifyIORef, newIORef)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word             (Word32, Word64)
import System.IO.Unsafe      (unsafePerformIO)

import qualified System.Random as R

#if !__GHCJS__
import System.CPUTime        (cpuTimePrecision, getCPUTime)
#endif

#if MIN_VERSION_base(4,7,0)
import Data.Bits (finiteBitSize)
#else
import Data.Bits (bitSize)
#endif

#if MIN_VERSION_base(4,5,0)
import Data.Bits             (popCount)
#else
import Data.Bits             ((.&.))
popCount :: Word32 -> Int
popCount = go 0
 where
   go !c 0 = c
   go c w = go (c+1) (w .&. (w - 1)) -- clear the least significant
#endif

-- $setup
-- >>> import Text.Read (readMaybe)
-- >>> import Data.List (unfoldr)
-- >>> import Text.Printf (printf)

-------------------------------------------------------------------------------
-- Generator
-------------------------------------------------------------------------------

-- | SplitMix generator state.
data SMGen = SMGen {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 -- seed and gamma; gamma is odd
  deriving Show

instance NFData SMGen where
    rnf (SMGen _ _) = ()

-- |
--
-- >>> readMaybe "SMGen 1 1" :: Maybe SMGen
-- Just (SMGen 1 1)
--
-- >>> readMaybe "SMGen 1 2" :: Maybe SMGen
-- Nothing
--
-- >>> readMaybe (show (mkSMGen 42)) :: Maybe SMGen
-- Just (SMGen 142593372 1604540297)
--
instance Read SMGen where
    readsPrec d r =  readParen (d > 10) (\r0 ->
        [ (SMGen seed gamma, r3)
        | ("SMGen", r1) <- lex r0
        , (seed, r2) <- readsPrec 11 r1
        , (gamma, r3) <- readsPrec 11 r2
        , odd gamma
        ]) r

-------------------------------------------------------------------------------
-- Operations
-------------------------------------------------------------------------------

-- | Generate a 'Word32'.
--
-- >>> take 3 $ map (printf "%x") $ unfoldr (Just . nextWord32) (mkSMGen 1337) :: [String]
-- ["e0cfe722","a6ced0f0","c3a6d889"]
--
nextWord32 :: SMGen -> (Word32, SMGen)
nextWord32 (SMGen seed gamma) = (mix32 seed', SMGen seed' gamma)
  where
    seed' = seed + gamma

-- | Generate a 'Word64', by generating to 'Word32's.
nextWord64 :: SMGen -> (Word64, SMGen)
nextWord64 s0 = (fromIntegral w0 `shiftL` 32 .|. fromIntegral w1,  s2)
  where
    (w0, s1) = nextWord32 s0
    (w1, s2) = nextWord32 s1

-- | Generate two 'Word32'.
nextTwoWord32 :: SMGen -> (Word32, Word32, SMGen)
nextTwoWord32 s0 = (w0, w1, s2) where
    (w0, s1) = nextWord32 s0
    (w1, s2) = nextWord32 s1

-- | Generate an 'Int'.
nextInt :: SMGen -> (Int, SMGen)
nextInt g | isBigInt  = int64
          | otherwise = int32
  where
    int32 = case nextWord32 g of
        (w, g') -> (fromIntegral w, g')
    int64 = case nextWord64 g of
        (w, g') -> (fromIntegral w, g')

isBigInt :: Bool
isBigInt =
#if MIN_VERSION_base(4,7,0)
    finiteBitSize (undefined :: Int) > 32
#else
    bitSize       (undefined :: Int) > 32
#endif

-- | Generate a 'Double' in @[0, 1)@ range.
--
-- >>> take 8 $ map (printf "%0.3f") $ unfoldr (Just . nextDouble) (mkSMGen 1337) :: [String]
-- ["0.878","0.764","0.063","0.845","0.262","0.490","0.176","0.544"]
--
nextDouble :: SMGen -> (Double, SMGen)
nextDouble g = case nextWord64 g of
    (w64, g') -> (fromIntegral (w64 `shiftR` 11) * doubleUlp, g')

-- | Generate a 'Float' in @[0, 1)@ range.
--
-- >>> take 8 $ map (printf "%0.3f") $ unfoldr (Just . nextFloat) (mkSMGen 1337) :: [String]
-- ["0.878","0.652","0.764","0.631","0.063","0.180","0.845","0.645"]
--
nextFloat :: SMGen -> (Float, SMGen)
nextFloat g = case nextWord32 g of
    (w32, g') -> (fromIntegral (w32 `shiftR` 8) * floatUlp, g')

-- | Split a generator into a two uncorrelated generators.
splitSMGen :: SMGen -> (SMGen, SMGen)
splitSMGen (SMGen seed gamma) =
    (SMGen seed'' gamma, SMGen (mix32 seed') (mixGamma seed''))
  where
    seed'  = seed + gamma
    seed'' = seed' + gamma

-------------------------------------------------------------------------------
-- Algorithm
-------------------------------------------------------------------------------

-- | (1 + sqrt 5) / 2 * (2 ^^ bits)
goldenGamma :: Word32
goldenGamma = 0x9e3779b9

floatUlp :: Float
floatUlp =  1.0 / fromIntegral (1 `shiftL` 24 :: Word32)

doubleUlp :: Double
doubleUlp =  1.0 / fromIntegral (1 `shiftL` 53 :: Word64)

#if defined(__GHCJS__) && defined(OPTIMISED_MIX32)
-- JavaScript Foreign Function Interface
-- https://github.com/ghcjs/ghcjs/blob/master/doc/foreign-function-interface.md

foreign import javascript unsafe
    "var x0 = $1 ^ $1 >>> 16; var x1 = x0 & 0xffff; var x2 = (((x0 >>> 16 & 0xffff) * 0x0000ca6b + x1 * 0x000085eb & 0xffff) << 16) + x1 * 0x0000ca6b; var x3 = x2 ^ x2 >>> 13; var x4 = x3 & 0xffff; var x5 = (((x3 >>> 16 & 0xffff) * 0x0000ae35 + x4 * 0x0000c2b2 & 0xffff) << 16) + x4 * 0x0000ae35; $r = (x5 ^ x5 >>> 16) | 0;"
    mix32 :: Word32 -> Word32

foreign import javascript unsafe
    "var x0 = $1 ^ $1 >>> 16; var x1 = x0 & 0xffff; var x2 = (((x0 >>> 16 & 0xffff) * 0x00006ccb + x1 * 0x000069ad & 0xffff) << 16) + x1 * 0x00006ccb; var x3 = x2 ^ x2 >>> 13; var x4 = x3 & 0xffff; var x5 = (((x3 >>> 16 & 0xffff) * 0x0000b5b3 + x4 * 0x0000cd9a & 0xffff) << 16) + x4 * 0x0000b5b3; $r = (x5 ^ x5 >>> 16) | 0;"
    mix32variant13 :: Word32 -> Word32

#else
mix32 :: Word32 -> Word32
mix32 z0 =
   -- MurmurHash3Mixer 32bit
    let z1 = shiftXorMultiply 16 0x85ebca6b z0
        z2 = shiftXorMultiply 13 0xc2b2ae35 z1
        z3 = shiftXor 16 z2
    in z3

-- used only in mixGamma
mix32variant13 :: Word32 -> Word32
mix32variant13 z0 =
   -- See avalanche "executable"
    let z1 = shiftXorMultiply 16 0x69ad6ccb z0
        z2 = shiftXorMultiply 13 0xcd9ab5b3 z1
        z3 = shiftXor 16 z2
    in z3

shiftXor :: Int -> Word32 -> Word32
shiftXor n w = w `xor` (w `shiftR` n)

shiftXorMultiply :: Int -> Word32 -> Word32 -> Word32
shiftXorMultiply n k w = shiftXor n w * k
#endif

mixGamma :: Word32 -> Word32
mixGamma z0 =
    let z1 = mix32variant13 z0 .|. 1             -- force to be odd
        n  = popCount (z1 `xor` (z1 `shiftR` 1))
    -- see: http://www.pcg-random.org/posts/bugs-in-splitmix.html
    -- let's trust the text of the paper, not the code.
    in if n >= 12
        then z1
        else z1 `xor` 0xaaaaaaaa

-------------------------------------------------------------------------------
-- Initialisation
-------------------------------------------------------------------------------

-- | Create 'SMGen' using seed and gamma.
--
-- >>> seedSMGen 2 2
-- SMGen 2 3
--
seedSMGen
    :: Word32 -- ^ seed
    -> Word32 -- ^ gamma
    -> SMGen
seedSMGen seed gamma = SMGen seed (gamma .|. 1)

-- | Like 'seedSMGen' but takes a pair.
seedSMGen' :: (Word32, Word32) -> SMGen
seedSMGen' = uncurry seedSMGen

-- | Extract current state of 'SMGen'.
unseedSMGen :: SMGen -> (Word32, Word32)
unseedSMGen (SMGen seed gamma) = (seed, gamma)

-- | Preferred way to deterministically construct 'SMGen'.
--
-- >>> mkSMGen 42
-- SMGen 142593372 1604540297
--
mkSMGen :: Word32 -> SMGen
mkSMGen s = SMGen (mix32 s) (mixGamma (s + goldenGamma))

-- | Initialize 'SMGen' using system time.
initSMGen :: IO SMGen
initSMGen = fmap mkSMGen mkSeedTime

-- | Derive a new generator instance from the global 'SMGen' using 'splitSMGen'.
newSMGen :: IO SMGen
newSMGen = atomicModifyIORef theSMGen splitSMGen

theSMGen :: IORef SMGen
theSMGen = unsafePerformIO $ initSMGen >>= newIORef
{-# NOINLINE theSMGen #-}

mkSeedTime :: IO Word32
mkSeedTime = do
    now <- getPOSIXTime
    let lo = truncate now :: Word32
#if __GHCJS__
    let hi = lo
#else
    cpu <- getCPUTime
    let hi = fromIntegral (cpu `div` cpuTimePrecision) :: Word32
#endif
    return $ fromIntegral hi `shiftL` 32 .|. fromIntegral lo

-------------------------------------------------------------------------------
-- System.Random
-------------------------------------------------------------------------------

instance R.RandomGen SMGen where
    next = nextInt
    split = splitSMGen
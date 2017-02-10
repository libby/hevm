{-# Language OverloadedStrings #-}
{-# Language BangPatterns #-}
{-# Language LambdaCase #-}
{-# Language FlexibleContexts #-}
{-# Language TemplateHaskell #-}
{-# Language DeriveGeneric, DeriveAnyClass #-}

module EVM.Solidity (
  solidity, readSolc, SolcContract (..),
  solcCodehash, runtimeCode, name, abiMap, solcSrcmap,
  makeSrcMaps, SrcMap (..),
  JumpType (..), SourceCache (..), snippetCache, sourceFiles, sourceLines
) where

import EVM.Keccak

import Control.DeepSeq
import Control.Lens
import Data.Aeson.Lens
-- import Data.Attoparsec.Text
import Control.Applicative
import Data.DoubleWord
import Data.Foldable

import Data.ByteString (ByteString)
import Data.Sequence (Seq)
import Data.ByteString.Lazy (toStrict)
import Data.ByteString.Builder
import Data.Map.Strict (Map)
import Data.Maybe
import Data.Monoid
import Data.Vector (Vector, (!))
import Data.Text (Text, pack, intercalate)
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO (readFile, writeFile)
import Data.Word
import Data.Char (isDigit, digitToInt)
import GHC.Generics (Generic)
import Prelude hiding (readFile, writeFile)
import System.IO hiding (readFile, writeFile)
import System.IO.Temp
import System.Process

import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HMap
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Vector as Vector

instance NFData Word128
instance NFData Word256

data JumpType = JumpInto | JumpFrom | JumpRegular
  deriving (Show, Eq, Ord, Generic, NFData)

data SrcMap = SM {
  srcMapOffset :: !Int,
  srcMapLength :: !Int,
  srcMapFile   :: !Int,
  srcMapJump   :: !JumpType
} deriving (Show, Eq, Ord, Generic, NFData)

data SrcMapParseState = F1 [Int]
                      | F2 !Int [Int]
                      | F3 !Int !Int [Int] !Int
                      | F4 !Int !Int !Int
                      | F5 !SrcMap
                      | Fe
                      deriving Show

-- I'm very sorry about this.  I was up late and couldn't figure out
-- how to use Attoparsec in a good way, and I figured I would just
-- write a damn state machine.  This should probably just be a
-- regular expression thing?!
makeSrcMaps :: Text -> Maybe (Seq SrcMap)
makeSrcMaps = (\case (_, Fe, _) -> Nothing; x -> Just (done x))
             . Text.foldl' (\x y -> go y x) (mempty, F1 [], SM 0 0 0 JumpRegular)
  where
    digits ds = digits' (0 :: Int) (0 :: Int) ds
    digits' !x _ []      = x
    digits' !x !n (d:ds) = digits' (x + d * 10 ^ n) (n + 1) ds

    done (xs, s, p) = let (xs', _, _) = go ';' (xs, s, p) in xs'
    
    go ':' (xs, F1 [], p@(SM a _ _ _))       = (xs, F2 a [], p)
    go ':' (xs, F1 ds, p)                    = (xs, F2 (digits ds) [], p)
    go d   (xs, F1 ds, p) | isDigit d        = (xs, F1 (digitToInt d : ds), p)
    go ';' (xs, F1 [], p)                    = (xs |> p, F1 [], p)
    go ';' (xs, F1 ds, SM _ b c d)           = let p' = SM (digits ds) b c d in
                                               (xs |> p', F1 [], p')

    go d   (xs, F2 a ds, p) | isDigit d      = (xs, F2 a (digitToInt d : ds), p)
    go ':' (xs, F2 a [], p@(SM _ b _ _))     = (xs, F3 a b [] 1, p)
    go ':' (xs, F2 a ds, p)                  = (xs, F3 a (digits ds) [] 1, p)
    go ';' (xs, F2 a [], SM _ b c d)         = let p' = SM a b c d in (xs |> p', F1 [], p')
    go ';' (xs, F2 a ds, SM _ _ c d)         = let p' = SM a (digits ds) c d in
                                               (xs |> p', F1 [], p')

    go d   (xs, F3 a b ds k, p) | isDigit d  = (xs, F3 a b (digitToInt d : ds) k, p)
    go '-' (xs, F3 a b [] _, p)              = (xs, F3 a b [] (-1), p)
    go ':' (xs, F3 a b [] _, p@(SM _ _ c _)) = (xs, F4 a b c, p)
    go ':' (xs, F3 a b ds k, p)              = (xs, F4 a b (k * digits ds), p)
    go ';' (xs, F3 a b [] _, SM _ _ c d)     = let p' = SM a b c d in (xs |> p', F1 [], p')
    go ';' (xs, F3 a b ds k, SM _ _ _ d)     = let p' = SM a b (k * digits ds) d in
                                               (xs |> p', F1 [], p')

    go 'i' (xs, F4 a b c, p)                 = (xs, F5 (SM a b c JumpInto), p)
    go 'o' (xs, F4 a b c, p)                 = (xs, F5 (SM a b c JumpFrom), p)
    go '-' (xs, F4 a b c, p)                 = (xs, F5 (SM a b c JumpRegular), p)
    go ';' (xs, F5 s, _)                     = (xs |> s, F1 [], s)

    go _ (xs, _, p)                          = (xs, Fe, p)
    
data SolcContract = SolcContract {
  _solcCodehash :: Word256,
  _runtimeCode :: ByteString,
  _name :: Text,
  _abiMap :: Map Word32 Text,
  _solcSrcmap :: Seq SrcMap
} deriving (Show, Eq, Ord, Generic, NFData)
makeLenses ''SolcContract

data SourceCache = SourceCache {
  _snippetCache :: Map (Int, Int) ByteString,
  _sourceFiles  :: Map Int (Text, ByteString),
  _sourceLines  :: Map Int (Vector ByteString)
} deriving (Show, Eq, Ord, Generic, NFData)
makeLenses ''SourceCache

instance Monoid SourceCache where
  mempty = SourceCache mempty mempty mempty
  mappend (SourceCache a b c) (SourceCache d e f) = error "lol"

makeSourceCache :: [Text] -> IO SourceCache
makeSourceCache paths = do
  xs <- mapM (BS.readFile . Text.unpack) paths
  return $! SourceCache {
    _snippetCache = mempty,
    _sourceFiles = Map.fromList (zip [1 .. length paths] (zip paths xs)),
    _sourceLines = Map.fromList (zip [1 .. length paths] (map (Vector.fromList . BS.split 0xa) xs))
  }

readSolc :: FilePath -> IO (Maybe (Map Text SolcContract, SourceCache))
readSolc fp =
  (readJSON <$> readFile fp) >>=
    \case Nothing -> return Nothing
          Just (contracts, sources) -> do
            sourceCache <- makeSourceCache sources
            return $! Just (contracts, sourceCache)

solidity :: Text -> Text -> IO (Maybe ByteString)
solidity contract src = do
  Just (solc, _) <- readJSON <$> solidity' src
  return (solc ^? ix contract . runtimeCode)

readJSON :: Text -> Maybe (Map Text SolcContract, [Text])
readJSON json = do
  contracts <- f <$> (json ^? key "contracts" . _Object)
                 <*> (fmap (fmap (\x -> x ^. _String)) $ json ^? key "sourceList" . _Array)
  sources <- toList . fmap (view _String) <$> json ^? key "sourceList" . _Array
  return (contracts, sources)
  where
    f x y = Map.fromList . map (g y) . HMap.toList $ x
    g srcs (s, x) =
      let theCode = toCode (x ^?! key "bin-runtime" . _String)
      in (s, SolcContract {
        _solcCodehash = keccak theCode,
        _runtimeCode = theCode,
        _name = s,
        _abiMap = Map.fromList $
          flip map (toList $ (x ^?! key "abi" . _String) ^?! _Array) $
            \abi -> (
              abiKeccak (encodeUtf8 (signature abi)),
              signature abi
            ),
        _solcSrcmap = fromJust (makeSrcMaps (x ^?! key "srcmap-runtime" . _String))
      })

signature :: AsValue s => s -> Text
signature abi =
  case abi ^?! key "type" of
    "fallback" -> "<fallback>"
    _ ->
      fold [
        fromMaybe "<constructor>" (abi ^? key "name" . _String), "(",
        intercalate ","
          (map (\x -> x ^?! key "type" . _String)
            (toList $ abi ^?! key "inputs" . _Array)),
        ")"
      ]


toCode :: Text -> ByteString
toCode = toStrict . toLazyByteString . fst . Text.foldl' go (mempty, Nothing)
  where
    go (s, Nothing) a = (s, Just $! digitToInt a)
    go (s, Just a)  b =
      let !x = fromIntegral (a * 16 + digitToInt b)
      in (s <> word8 x, Nothing)

solidity' :: Text -> IO Text
solidity' src = withSystemTempFile "hsevm.sol" $ \path handle -> do
  hClose handle
  writeFile path ("pragma solidity ^0.4.8;\n" <> src)
  pack <$> readProcess "solc" ["--combined-json=bin-runtime", path] ""
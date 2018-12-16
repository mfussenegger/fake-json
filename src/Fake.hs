{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Fake (
  State,
  Env(..),
  newEnv,
  eval,
  runExpr
) where

import qualified Aeson                      as A
import           Control.Monad              (forM, replicateM)
import           Control.Monad.IO.Class     (liftIO)
import           Control.Monad.State.Class  (MonadState)
import           Control.Monad.State.Strict (StateT)
import qualified Control.Monad.State.Strict as State
import           Data.Aeson                 (Value (..), object)
import qualified Data.ByteString.Char8      as BS
import qualified Data.HashMap.Strict        as M
import           Data.Maybe                 (fromMaybe)
import qualified Data.Scientific            as S
import qualified Data.Set                   as Set
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as T
import qualified Data.UUID                  as UUID
import qualified Data.UUID.V1               as UUID1
import qualified Data.Vector                as V
import           Expr                       (Expr (..))
import           Prelude                    hiding (lines, replicate)
import           System.Random              (Random (..), RandomGen (..),
                                             StdGen, mkStdGen, newStdGen)
import qualified Text.Regex.TDFA.Pattern    as R
import qualified Text.Regex.TDFA.ReadRegex  as R


-- $setup
-- >>> :set -XOverloadedStrings
-- >>> let g = Env (mkStdGen 1) M.empty
-- >>> let exec expr = State.evalStateT (eval expr) g


type State a = StateT Env IO a


data Env = Env
  { envStdGen :: StdGen
  , envFileCache :: M.HashMap T.Text (V.Vector Value) }


instance RandomGen Env where
  next env = (x, env { envStdGen = g' })
    where
      (x, g') = next (envStdGen env)
  split env = (env { envStdGen = g' }, env { envStdGen = g'' })
    where
      (g', g'') = split (envStdGen env)


runExpr :: Int -> Expr -> IO Value
runExpr seed expr = State.evalStateT (eval expr) env
  where
    env = Env (mkStdGen seed) M.empty


newEnv :: IO Env
newEnv = do
  stdGen <- newStdGen
  pure $ Env stdGen M.empty


uuid1 :: IO UUID.UUID
uuid1 = do
  uuid <- UUID1.nextUUID
  case uuid of
    (Just u) -> pure u
    Nothing  -> uuid1


-- | Generate a random int
--
-- >>> exec "randomInt(1, 2)"
-- Number 1.0
randomInt :: Expr -> Expr -> State Value
randomInt lower upper = do
  lower' <- A.asInt <$> eval lower
  upper' <- A.asInt <$> eval upper
  Number . fromIntegral <$> State.state (randomR (lower', upper'))


-- | Generate a random double
--
-- >>> exec "randomDouble(1.5, 3)"
-- Number 1.500000257527587
randomDouble :: Expr -> Expr -> State Value
randomDouble lower upper = do
  lower' <- A.asDouble <$> eval lower
  upper' <- A.asDouble <$> eval upper
  Number . S.fromFloatDigits <$> State.state (randomR (lower', upper'))


-- | Generate a random boolean
--
-- >>> exec "randomBool"
-- Bool False
randomBool :: Monad m => StateT Env m Value
randomBool = Bool <$> State.state random


-- | Select one random item of an array
--
-- >>> exec "oneOf(array(37, 42, 21))"
-- Number 21.0
oneOfArray :: Expr -> State Value
oneOfArray arr = do
  arr' <- A.asArray <$> eval arr
  idx <- State.state $ randomR (0, length arr' - 1)
  pure $ arr' V.! idx


-- | Select one random argument
--
-- >>> exec "oneOf(37, 42, 21)"
-- Number 21.0
--
-- >>> env <- newEnv
-- >>> State.evalStateT (oneOfArgs []) env
-- Nothing
oneOfArgs :: [Expr] -> State (Maybe Value)
oneOfArgs args = do
  rndArg <- rndListItem args
  case rndArg of
    Nothing  -> pure Nothing
    Just arg -> Just <$> eval arg


-- | Create an array with `num` items
--
-- >>> exec "replicate(randomInt(2, 4), oneOf(37, 42, 21))"
-- Array [Number 42.0,Number 42.0,Number 21.0,Number 42.0]
--
replicate :: Expr -> Expr -> State Value
replicate num expr = do
  num' <- A.asInt <$> eval num
  Array <$> V.replicateM num' (eval expr)


-- | Create an object from a list in the  [key, value [, ...]] form
--
-- >>> exec "object('x', randomInt(2, 4), oneOf('y', 'z'), 3)"
-- Object (fromList [("z",Number 3.0),("x",Number 4.0)])
-- 
objectFromArgs :: [Expr] -> State Value
objectFromArgs args = do
  let
    keyValuePairs = mkPairs (fmap eval args)
    mkPairs [] = []
    mkPairs [_] = error "Arguments to object must be a multiple of 2 (key + value pairs)"
    mkPairs (x : y : rest) = (x, y) : mkPairs rest
  pairs <- forM keyValuePairs (\(key, val) -> do
    key' <- A.asText <$> key
    val' <- val
    pure (key', val'))
  pure $ object pairs


rndListItem :: (RandomGen g, MonadState g m) => [a] -> m (Maybe a)
rndListItem [] = pure Nothing
rndListItem xs = do
  idx <- State.state $ randomR (0, length xs - 1)
  pure . Just $ xs !! idx


rndSetItem :: Monad m => Set.Set a -> StateT Env m a
rndSetItem xs = do
  idx <- State.state $ randomR (0, Set.size xs - 1)
  pure $ Set.elemAt idx xs


allPossibleChars :: Set.Set Char
allPossibleChars = Set.fromList [minBound..maxBound]


-- | Create random data that would be matched by the given regex
--
-- >>> exec "fromRegex('\\d-\\d{1,3}-FOO')"
-- String "5-67-FOO"
--
-- >>> exec "fromRegex('[a-z]{3}')"
-- String "esh"
--
-- >>> exec "fromRegex('[^0-9][0-9]B')"
-- String "\211735\&4B"
fromRegex :: Monad m => T.Text -> StateT Env m Value
fromRegex input =
  case R.parseRegex input' of
    (Left err)           -> error $ show err
    (Right (pattern, _)) -> String <$> generateText pattern
  where
    input' = T.unpack input
    defaultUpper = 10
    replicatePattern lower upper pattern = do
      numChars <- State.state $ randomR (lower, upper)
      T.concat <$> replicateM numChars (generateText pattern)
    generateText p = case p of
      (R.POr patterns) -> do
        pattern <- rndListItem patterns
        case pattern of
          Nothing       -> pure $ ""
          Just pattern' -> generateText pattern'
      (R.PConcat patterns) -> T.concat <$> mapM generateText patterns
      (R.PPlus pattern) -> replicatePattern 1 defaultUpper pattern
      (R.PStar _ pattern) -> replicatePattern 0 defaultUpper pattern
      (R.PBound lower mUpper pattern) -> do
        replicatePattern lower (fromMaybe defaultUpper mUpper) pattern
      (R.PAny _ patternSet) -> fromPatternSet patternSet
      (R.PAnyNot _ ps@(R.PatternSet mChars _ _ _)) -> case mChars of
        (Just notAllowedChars) ->
          charToText <$> rndSetItem (Set.difference allPossibleChars notAllowedChars)
        Nothing -> error $ "Can't generate data from regex pattern" <> show ps
      (R.PEscape _ 'd') -> do
        T.pack . show <$> (State.state $ randomR (0, 9 :: Int))
      (R.PChar _ char) -> pure $ charToText char
      _ -> error $ "Can't generate data from regex pattern" <> show p
    fromPatternSet ps@(R.PatternSet mCharSet _ _ _) =
      case mCharSet of
        (Just charSet) -> charToText <$> rndSetItem charSet
        Nothing -> error $ "Can't generate data from regex pattern" <> show ps
    charToText c = T.pack [c]


fromFile :: Expr -> State Value
fromFile fileName = do
  fileName' <- A.asText <$> eval fileName
  e@Env{..} <- State.get
  case M.lookup fileName' envFileCache of
    (Just lines) -> pure $ Array lines
    Nothing      -> do
      contents <- liftIO $ BS.readFile (T.unpack fileName')
      let
        lines = V.fromList $ fmap (String . T.decodeUtf8) (BS.lines contents)
      State.put e { envFileCache = M.insert fileName' lines envFileCache }
      pure $ Array lines


-- | Generate a random character
--
-- >>> exec "randomChar()"
-- String "\629160"
randomChar :: Monad m => StateT Env m Value
randomChar = charToString <$> State.state random
  where
    charToString :: Char -> Value
    charToString = String . T.pack . (: [])

maybeFail :: Monad m => String -> m (Maybe a) -> m a
maybeFail err x  = do
  x' <- x
  case x' of
    Nothing  -> error err
    Just x'' -> pure x''

-- | Create a value getter for an expression
--
-- >>> exec "uuid4"
-- String "0099a82c-36f7-4321-8012-daa4305fd84b"
--
-- >>> exec "array(randomInt(1, 10), randomDouble(1, 20))"
-- Array [Number 5.0,Number 1.0000012432210876]
--
eval :: Expr -> State Value
eval (IntLiteral x)    = pure $ Number $ fromInteger x
eval (StringLiteral x) = pure $ String x
eval (DoubleLiteral x) = pure $ Number x
eval (FunctionCall "uuid4" []) = String . UUID.toText <$> State.state random
eval (FunctionCall "uuid1" []) = String . UUID.toText <$> liftIO uuid1
eval (FunctionCall "null" []) = pure Null
eval (FunctionCall "randomBool" []) = randomBool
eval (FunctionCall "randomChar" []) = randomChar
eval (FunctionCall "randomInt" [lower, upper]) = randomInt lower upper
eval (FunctionCall "randomDouble" [lower, upper]) = randomDouble lower upper
eval (FunctionCall "array" args) = Array . V.fromList <$> mapM eval args
eval (FunctionCall "oneOf" [arg]) = oneOfArray arg
eval (FunctionCall "oneOf" args) =
  maybeFail "oneOf requires at least 1 argument" (oneOfArgs args)
eval (FunctionCall "replicate" [num, expr]) = replicate num expr
eval (FunctionCall "object" args) = objectFromArgs args
eval (FunctionCall "fromFile" [fileName]) = fromFile fileName
eval (FunctionCall "fromRegex" [pattern]) = eval pattern >>= fromRegex . A.asText
eval (FunctionCall name _) = error $ "No random generator for " <> T.unpack name

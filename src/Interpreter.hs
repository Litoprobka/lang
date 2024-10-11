{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
module Interpreter where

import CheckerTypes (Name)
import Relude
import Syntax.Row (OpenName)
import Syntax
import Syntax.Expression qualified as E
import Data.HashMap.Lazy qualified as HashMap -- note that we use the lazy functions here
import qualified Syntax.Pattern as P
import qualified Syntax.Row as Row
import qualified GHC.IsList as IsList
import Prettyprinter (Pretty, pretty, (<+>), sep, braces, punctuate, comma, parens)

data Value
    = Constructor Name [Value] -- a fully-applied counstructor
    | Lambda (Value -> Value)
    | Record (Row Value)
    | Variant OpenName Value
    | RecordLens (NonEmpty OpenName)
    | Text Text
    | Char Text
    | Int Int

instance Pretty Value where
    pretty = \case
        Constructor name args -> parens $ pretty name <+> sep (pretty <$> args)
        Lambda _ -> "<lambda>"
        Record row -> braces . sep . punctuate comma . map recordField $ Row.sortedRow row
        Variant name val -> parens $ pretty name <+> pretty val
        RecordLens lens -> foldMap (("." <>) . pretty) lens
        Text txt -> pretty txt
        Char c -> pretty c
        Int n -> pretty n

      where
        recordField (name, body) = pretty name <+> "=" <+> pretty body

-- placeholder
showValue :: Value -> Text
showValue _ = "<value>"

data InterpreterBuiltins a = InterpreterBuiltins
    { true :: a
    , cons :: a
    , nil :: a
    } deriving (Functor, Foldable, Traversable)

eval :: InterpreterBuiltins Name -> HashMap Name Value -> HashMap Name Value -> Expression Name -> Value
eval builtins constrs = go where
  go env = \case
    E.Lambda pat body -> Lambda \arg -> go (forceMatch env pat arg) body
    E.Application f arg -> case go env f of
        Lambda closure -> closure (go env arg)
        other -> error $ "cannot apply " <> showValue other
    E.Annotation x _ -> go env x
    E.Let binding body -> case binding of
        E.ValueBinding pat bindingBody -> go (forceMatch env pat $ go env bindingBody) body
        E.FunctionBinding name args bindingBody ->
            go (HashMap.insert name (go env $ foldr E.Lambda bindingBody args) env) body
    E.Case arg matches ->
        let val = go env arg
        in fromMaybe (error "pattern mismatch")
        $ asum $ (\(pat, body) -> flip go body <$> match env pat val) <$> matches
    E.Match matches@(m : _) -> mkLambda (length m) \args ->
        fromMaybe (error "no matches") $ asum $ uncurry (matchAllArgs env args) <$> matches
    E.Match [] -> error "empty match" -- shouldn't this be caught by type checking?
    E.If cond true false -> case go env cond of
        Constructor name [] | name == builtins.true -> go env true
        _ -> go env false
    E.Name name -> fromMaybe (error $ show name <> " not in scope") $ HashMap.lookup name env
    E.Constructor name ->  fromMaybe (error $ "unknown constructor " <> show name) $ HashMap.lookup name constrs
    E.RecordLens path -> RecordLens path
    E.Variant name -> Lambda $ Variant name
    E.Record row -> Record $ fmap (go env) row
    E.List xs -> foldr (\h t -> Constructor builtins.cons [go env h, t]) (Constructor builtins.nil []) xs
    E.IntLiteral n -> Int n
    E.TextLiteral txt -> Text txt
    E.CharLiteral c -> Char c

  forceMatch :: HashMap Name Value -> Pattern Name -> Value -> HashMap Name Value
  forceMatch env pat arg = fromMaybe (error "pattern mismatch") $ match env pat arg

  match :: HashMap Name Value -> Pattern Name -> Value -> Maybe (HashMap Name Value)
  match env = \cases
    (P.Var var) val -> Just $ HashMap.insert var val env
    (P.Annotation pat _) val -> match env pat val
    (P.Variant name argPat) (Variant name' arg)
        | name == name' -> match env argPat arg
        | otherwise -> Nothing
    (P.Record patRow) (Record valRow) -> do
        valPatPairs <- traverse (\(name, pat) -> (pat, ) <$> Row.lookup name valRow) $ IsList.toList patRow
        fold <$> traverse (uncurry $ match env) valPatPairs
    (P.Constructor name pats) (Constructor name' args) -> do
        guard (name == name')
        guard (length pats == length args)
        fold <$> zipWithM (match env) pats args
    (P.List (pat : pats)) (Constructor name [h, t]) | name == builtins.cons -> do
        env' <- match env pat h
        match env' (P.List pats) t
    (P.List []) (Constructor name []) | name == builtins.nil -> Just env
    (P.IntLiteral n) (Int m) -> env <$ guard (n == m)
    (P.TextLiteral txt) (Text txt') -> env <$ guard (txt == txt')
    (P.CharLiteral c) (Char c') -> env <$ guard (c == c')
    _ _ -> Nothing

  mkLambda :: Int -> ([Value] -> Value) -> Value
  mkLambda 0 f = f []
  mkLambda n f = mkLambda (pred n) \args -> Lambda \x -> f (x : args)

  matchAllArgs :: HashMap Name Value -> [Value] -> [Pattern Name] -> Expression Name -> Maybe Value
  matchAllArgs env args pats body = do
    env' <- fold <$> zipWithM (match env) pats args
    pure $ go env' body
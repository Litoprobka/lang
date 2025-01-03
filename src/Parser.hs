{-# HLINT ignore "Use <$>" #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

module Parser (code, declaration, type', pattern', expression, parseModule) where

import Relude hiding (many, some)

import Lexer
import Syntax
import Syntax.Declaration qualified as D
import Syntax.Expression qualified as E
import Syntax.Pattern qualified as P
import Syntax.Type qualified as T

import Control.Monad.Combinators.Expr qualified as Expr
import Control.Monad.Combinators.NonEmpty qualified as NE

import Common (
    Fixity (..),
    Loc (..),
    Located (..),
    Pass (..),
    PriorityRelation' (..),
    SimpleName,
    SimpleName_ (..),
    locFromSourcePos,
    zipLocOf,
 )
import Data.List.NonEmpty qualified as NE
import Data.Sequence qualified as Seq
import Diagnostic (Diagnose, fatal, reportsFromBundle)
import Effectful (Eff, (:>))
import Syntax.Row
import Syntax.Row qualified as Row
import Text.Megaparsec
import Text.Megaparsec.Char (string)

parseModule :: Diagnose :> es => (FilePath, Text) -> Eff es [Declaration 'Parse]
parseModule (fileName, fileContents) = either (fatal . reportsFromBundle) pure $ parse (usingReaderT pos1 code) fileName fileContents

code :: Parser [Declaration 'Parse]
code = topLevelBlock declaration

declaration :: Parser (Declaration 'Parse)
declaration = withLoc $ choice [typeDec, fixityDec, signature, valueDec]
  where
    valueDec = do
        flip3 D.Value <$> binding <*> whereBlock
    whereBlock = option [] $ block "where" (withLoc valueDec)

    typeDec = keyword "type" *> (typeAliasDec <|> typeDec')
    typeAliasDec = do
        keyword "alias"
        name <- typeName
        specialSymbol "="
        flip3 D.Alias name <$> type'

    typeDec' = do
        name <- typeName
        vars <- many typeVariable -- in the future, this should also support kind-annotated variables
        specialSymbol "="
        flip4 D.Type name vars <$> typePattern `sepBy` specialSymbol "|"

    typePattern :: Parser (Constructor 'Parse)
    typePattern = withLoc do
        name <- typeName
        args <- many typeParens
        pure $ flip3 D.Constructor name args

    signature = do
        name <- try $ (operatorInParens <|> termName) <* specialSymbol ":"
        flip3 D.Signature name <$> type'

    fixityDec = do
        keyword "infix"
        fixity <-
            choice
                [ InfixL <$ keyword "left"
                , InfixR <$ keyword "right"
                , InfixChain <$ keyword "chain"
                , pure Infix
                ]
        op <- someOperator
        above <- option [] do
            keyword "above"
            commaSep (Just <$> someOperator <|> Nothing <$ keyword "application")
        below <- option [] do
            keyword "below"
            commaSep someOperator
        equal <- option [] do
            keyword "equals"
            commaSep someOperator
        pure $ \loc -> D.Fixity loc fixity op PriorityRelation{above, below, equal}

type' :: ParserM m => m (Type' 'Parse)
type' = Expr.makeExprParser typeParens [[typeApp], [function], [forall', exists]]
  where
    forall' = Expr.Prefix $ lambdaLike T.Forall forallKeyword typeVariable "."
    exists = Expr.Prefix $ lambdaLike T.Exists existsKeyword typeVariable "."

    typeApp = Expr.InfixL $ pure T.Application
    function = Expr.InfixR $ appLoc T.Function <$ specialSymbol "->"
    appLoc con lhs rhs = con (zipLocOf lhs rhs) lhs rhs

-- a type expression with higher precedence than application
-- used when parsing constructor argument types and the like
typeParens :: ParserM m => m (Type' 'Parse)
typeParens =
    label "type" $
        choice
            [ T.Name <$> typeName
            , T.Var <$> typeVariable
            , parens type'
            , withLoc' T.Record $ NoExtRow <$> someRecord ":" type' Nothing
            , withLoc' T.Variant $ NoExtRow <$> brackets (fromList <$> commaSep variantItem)
            ]
  where
    variantItem = (,) <$> variantConstructor <*> option (T.Name $ Located Blank $ Name' "Unit") typeParens

someRecord :: ParserM m => Text -> m value -> Maybe (SimpleName -> value) -> m (Row value)
someRecord delim valueP missingValue = braces (fromList <$> commaSep recordItem)
  where
    onMissing name = case missingValue of
        Nothing -> id
        Just nameToValue -> option (nameToValue name)
    recordItem = do
        recordLabel <- termName
        valuePattern <- onMissing recordLabel $ specialSymbol delim *> valueP
        pure (recordLabel, valuePattern)

lambdaLike :: ParserM m => (Loc -> a -> b -> b) -> m () -> m a -> Text -> m (b -> b)
lambdaLike con kw argP endSym = do
    kw
    args <- NE.some $ (,) <$> getSourcePos <*> argP
    specialSymbol endSym
    end <- getSourcePos
    pure \body -> foldr (\(start, arg) -> con (locFromSourcePos start end) arg) body args

pattern' :: ParserM m => m (Pattern 'Parse)
pattern' =
    choice
        [ P.Constructor <$> typeName <*> many patternParens
        , P.Variant <$> variantConstructor <*> patternParens
        , patternParens
        ]

{- | parses a pattern with constructors enclosed in parens
should be used in cases where multiple patterns in a row are accepted, i.e.
function definitions and match expressions
-}
patternParens :: ParserM m => m (Pattern 'Parse)
patternParens = do
    pat <-
        choice
            [ P.Var <$> termName
            , lexeme $ withLoc' P.Wildcard $ string "_" <* option "" termName'
            , record
            , withLoc' P.List $ brackets (commaSep pattern')
            , P.Literal <$> literal
            , -- a constructor without arguments or with a tightly-bound record pattern
              lexeme $ P.Constructor <$> constructorName <*> option [] (one <$> record)
            , flip P.Variant unit <$> variantConstructor -- some sugar for variants with a unit payload
            , parens pattern'
            ]
    option pat do
        specialSymbol ":"
        P.Annotation pat <$> type'
  where
    record = withLoc' P.Record $ someRecord "=" pattern' (Just P.Var)
    unit = P.Record Blank Row.empty

binding :: ParserM m => m (Binding 'Parse)
binding = do
    f <-
        -- it should probably be `try (E.FunctionBinding <$> funcName) <*> NE.some patternParens
        -- for cleaner parse errors
        try (E.FunctionBinding <$> funcName <*> NE.some patternParens)
            <|> (E.ValueBinding <$> pattern')
    specialSymbol "="
    f <$> expression
  where
    -- we might want to support infix operator declarations in the future
    -- > f $ x = f x
    funcName = operatorInParens <|> termName

expression :: ParserM m => m (Expression 'Parse)
expression = expression' $ E.Name <$> termName

-- an expression with infix operators and unresolved priorities
-- the `E.Infix` constructor is only used when there is more than one operator
expression' :: ParserM m => m (Expression 'Parse) -> m (Expression 'Parse)
expression' termParser = do
    firstExpr <- noPrec termParser
    pairs <- many $ (,) <$> optional someOperator <*> noPrec termParser
    let expr = case pairs of
            [] -> firstExpr
            [(Nothing, secondExpr)] -> firstExpr `E.Application` secondExpr
            [(Just op, secondExpr)] -> E.Name op `E.Application` firstExpr `E.Application` secondExpr
            (_ : _ : _) -> uncurry (E.Infix E.Yes) $ shift firstExpr pairs
    option expr do
        specialSymbol ":"
        E.Annotation expr <$> type'
  where
    sameScopeExpr = expression' termParser

    -- overrides the term parser of expression to collect wildcards
    -- has to be called in the scope of `withWildcards`
    newScopeExpr :: ParserM m => StateT (Seq Loc) m (Expression 'Parse)
    newScopeExpr =
        expression' $
            nextVar
                <|> fmap E.Name termName

    -- x [(+, y), (*, z), (+, w)] --> [(x, +), (y, *), (z, +)] w
    shift expr [] = ([], expr)
    shift lhs ((op, rhs) : rest) = first ((lhs, op) :) $ shift rhs rest
    noPrec varParser = choice $ [varParser] <> keywordBased <> terminals

    -- expression forms that have a leading keyword/symbol
    keywordBased =
        [ -- note that we don't use `sameScopeExpression` here, since interleaving explicit and implicit lambdas, i.e. `(\f -> f _)`, is way too confusing
          lambdaLike E.Lambda lambda pattern' "->" <*> expression
        , letRec
        , let'
        , case'
        , match'
        , if'
        , doBlock
        , record
        , withWildcards $ withLoc $ flip E.List <$> brackets (commaSep newScopeExpr)
        , E.Name <$> operatorInParens -- operators are never wildcards, so it's okay to sidestep termParser here
        , parens $ withWildcards newScopeExpr
        ]
      where
        letRec = withLoc $ letRecBlock (try $ keyword "let" *> keyword "rec") (flip3 E.LetRec) binding expression
        let' =
            withLoc $
                letBlock "let" (flip3 E.Let) binding expression -- wildcards do not propagate through let bindings. Use an explicit lambda instead!
        case' = withLoc do
            keyword "case"
            arg <- expression -- `case _ of` is redundant, since it has the same meaning as a one arg `match`
            matches <- block "of" $ (,) <$> pattern' <* specialSymbol "->" <*> expression
            pure $ flip3 E.Case arg matches
        match' = withLoc $ flip E.Match <$> block "match" ((,) <$> some patternParens <* specialSymbol "->" <*> expression)
        if' = withLoc do
            keyword "if"
            cond <- sameScopeExpr
            keyword "then"
            true <- sameScopeExpr
            keyword "else"
            false <- sameScopeExpr
            pure $ flip4 E.If cond true false
        doBlock = withLoc do
            stmts <-
                block "do" $
                    choice
                        [ try $ E.Bind <$> pattern' <* specialSymbol "<-" <*> expression
                        , withLoc $ flip3 E.With <$ keyword "with" <*> pattern' <* specialSymbol "<-" <*> expression
                        , withLoc' E.DoLet $ keyword "let" *> binding
                        , E.Action <$> expression
                        ]
            case unsnoc stmts of
                Nothing -> fail "empty do block"
                Just (stmts', E.Action lastAction) -> pure $ flip3 E.Do stmts' lastAction
                _ -> fail "last statement in a do block must be an expression"
        unsnoc [] = Nothing
        unsnoc [x] = Just ([], x)
        unsnoc (x : xs) = first (x :) <$> unsnoc xs

    record =
        withWildcards $ withLoc $ flip E.Record <$> someRecord "=" newScopeExpr (Just E.Name)

    terminals =
        [ withLoc' E.RecordLens recordLens
        , constructor
        , E.Variant <$> variantConstructor
        , E.Literal <$> literal
        ]
    constructor = lexeme do
        name <- constructorName
        optional record <&> \case
            Nothing -> E.Constructor name
            Just arg -> E.Constructor name `E.Application` arg

-- turns out that respecting operator precedence makes for confusing code
-- i.e. consider, say, `3 + _ * 4`
-- with precendence, it should be parsed as `3 + (\x -> x * 4)`
-- but what you probably mean is `\x -> 3 + x * 4`
--
-- in the end, I decided to go with the simplest rules possible - that is, parens determine
-- the scope of the implicit lambda
--
-- it's not clear whether I want to require parens around list and record literals
-- on one hand, `({x = 3, y = 3})` looks a bit janky
-- on the other hand, without that you wouldn't be able to write `f {x = 3, y = _}`
-- if you want it to mean `\y -> f {x = 3, y}`
withWildcards :: ParserM m => StateT (Seq Loc) m (Expression 'Parse) -> m (Expression 'Parse)
withWildcards p = do
    -- todo: collect a list of wildcard names along with the counter
    ((expr, mbVarLocs), loc) <- withLoc $ (,) <$> runStateT p Seq.empty
    pure case NE.nonEmpty $ zip [1 ..] $ toList mbVarLocs of
        Just varLocs ->
            E.WildcardLambda loc ((\(i, varLoc) -> Located varLoc $ Wildcard' i) <$> varLocs) expr
        Nothing -> expr

-- foldr (\i -> E.Lambda loc (P.Var $ SimpleName Blank $ "$" <> show i)) expr [1 .. varCount]

nextVar :: ParserM m => StateT (Seq Loc) m (Expression 'Parse)
nextVar = do
    loc <- withLoc' const wildcard
    modify (Seq.|> loc)
    i <- gets Seq.length
    pure . E.Name . Located loc $ Wildcard' i

flip3 :: (a -> b -> c -> d) -> b -> c -> a -> d
flip3 f y z x = f x y z

flip4 :: (a -> b -> c -> d -> e) -> b -> c -> d -> a -> e
flip4 f y z w x = f x y z w

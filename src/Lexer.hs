{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use <$>" #-}
module Lexer (
    Parser,
    ParserM,
    keywords,
    specialSymbols,
    block,
    block1,
    topLevelBlock,
    letBlock,
    lexeme,
    lambda,
    keyword,
    specialSymbol,
    intLiteral,
    textLiteral,
    charLiteral,
    operator,
    termName,
    termName',
    typeName,
    typeVariable,
    variantConstructor,
    recordLens,
    parens,
    brackets,
    braces,
    commaSep,
    someOperator,
    wildcard,
    forallKeyword,
    existsKeyword,
    withLoc,
    withLoc',
    mkName,
    constructorName,
    literal,
    located,
    operatorInParens,
    letRecBlock,
) where

import Common (Literal, Literal_ (..), Loc (..), Located (..), SimpleName, SimpleName_ (..), locFromSourcePos)
import Control.Monad.Combinators.NonEmpty qualified as NE
import Data.Char (isAlphaNum, isSpace, isUpperCase)
import Data.HashSet qualified as Set
import Data.Text qualified as Text
import LangPrelude
import Relude.Monad (ask, local)
import Text.Megaparsec hiding (Token, token)
import Text.Megaparsec.Char hiding (newline, space)
import Text.Megaparsec.Char qualified as C (newline, space1)
import Text.Megaparsec.Char.Lexer qualified as L

type Parser = ReaderT Pos (Parsec Void Text)
type ParserM m = (MonadParsec Void Text m, MonadReader Pos m, MonadFail m)

-- |  the usual space parser. Doesn't consume newlines
space :: ParserM m => m ()
space = L.space nonNewlineSpace lineComment blockComment

{- | any non-zero amount of newlines and any amount of whitespace
  i.e. it skips lines of whitespace entirely
  should never be used outside of the block-parsing functions
-}
newlines :: ParserM m => m ()
newlines = C.newline *> L.space C.space1 lineComment blockComment

-- helper functions for @space@ and @newlines@
-- they're not in a where block, because monomorphism restriction
nonNewlineSpace, lineComment, blockComment :: ParserM m => m ()
nonNewlineSpace = void $ takeWhile1P (Just "space") \c -> isSpace c && c /= '\n' -- we can ignore \r here
lineComment =
    try $
        string "--"
            *> notFollowedBy (satisfy isOperatorChar)
            *> void (takeWhileP (Just "character") (/= '\n'))
            *> void (optional newline)
blockComment = L.skipBlockComment "---" "---" -- this syntax doesn't work well with nested comments; it does look neat though

-- | space or a newline with increased indentation
spaceOrLineWrap :: ParserM m => m ()
spaceOrLineWrap = void $ space `sepBy` newlineWithIndent
  where
    newlineWithIndent = try do
        baseIndent <- ask
        void $ L.indentGuard newlines GT baseIndent

{- | parses a statement separator
a \\n should have the same indent as previous blocks. A semicolon always works
-}
newline :: ParserM m => m ()
newline = label "separator" $ void (symbol ";") <|> eqIndent
  where
    eqIndent = try do
        indent <- ask
        void $ L.indentGuard newlines EQ indent

lexeme :: ParserM m => m a -> m a
lexeme = L.lexeme spaceOrLineWrap

symbol :: ParserM m => Text -> m Text
symbol = L.symbol spaceOrLineWrap

keywords :: HashSet Text
keywords =
    Set.fromList
        [ "if"
        , "then"
        , "else"
        , "type"
        , "alias"
        , "case"
        , "where"
        , "let"
        , "rec"
        , "match"
        , "of"
        , "forall"
        , "∀"
        , "exists"
        , "∃"
        , "do"
        , "with"
        , "infix"
        -- 'above', 'below', 'equals' and 'application' are conditional keywords - that is, they are allowed to be used as identifiers
        ]

-- | punctuation that has a special meaning, like keywords
specialSymbols :: HashSet Text
specialSymbols = Set.fromList ["=", "|", ":", ".", "λ", "\\", "∀", "∃", "->", "=>", "<-", "@", "~"]

-- lambda, forall and exists all have an ASCII and a unicode version

lambda :: ParserM m => m ()
lambda = void $ specialSymbol "\\" <|> specialSymbol "λ" -- should we allow `λx -> expr` without a space after λ?

forallKeyword :: ParserM m => m ()
forallKeyword = keyword "forall" <|> void (specialSymbol "∀")

existsKeyword :: ParserM m => m ()
existsKeyword = keyword "exists" <|> void (specialSymbol "∃")

-- | a helper for `block` and `block1`.
block'
    :: ParserM m
    => (forall b. m a -> m b -> m out)
    -- ^ `sep` parser. Intended uses are `sepEndBy` and `sepEndBy1`
    -> Text
    -- ^ keyword
    -> m a
    -- ^ statement parser
    -> m out
block' sep kw p = do
    keyword kw

    -- make sure that the block is indented at all
    -- prevents stuff like:
    -- > f x = expr where
    -- > expr = x + x
    -- that being said, the check wouldn't make sense if we also use `block` for
    -- top-level blocks
    --
    -- note that the preceding whitespace is already consumed by `keyword`
    void $ ask >>= L.indentGuard pass GT

    blockIndent <- L.indentLevel
    local (const blockIndent) (p `sep` newline)

block :: ParserM m => Text -> m a -> m [a]
block = block' sepEndBy

block1 :: ParserM m => Text -> m a -> m (NonEmpty a)
block1 = block' NE.sepEndBy1

{- | a newline-delimited expression
> let x = y
> z
-}
letBlock :: ParserM m => Text -> (a -> b -> c) -> m a -> m b -> m c
letBlock kw f declaration expression = do
    blockIndent <- L.indentLevel
    keyword kw
    dec <- declaration
    local (const blockIndent) do
        newline
        f dec <$> expression

letRecBlock :: ParserM m => m () -> (NonEmpty a -> b -> c) -> m a -> m b -> m c
letRecBlock kw f declaration expression = do
    outerIndent <- L.indentLevel
    kw
    innerIndent <- L.indentLevel
    decls <- local (const innerIndent) do
        declaration `NE.sepBy1` newline
    local (const outerIndent) do
        newline
        f decls <$> expression

topLevelBlock :: Parser a -> Parser [a]
topLevelBlock p = optional newlines *> L.nonIndented spaceOrLineWrap (p `sepEndBy` newline <* eof)

-- | intended to be called with one of `specialSymbols`
specialSymbol :: ParserM m => Text -> m ()
specialSymbol sym = label (toString sym) $ try $ lexeme $ string sym *> notFollowedBy (satisfy isOperatorChar) -- note that `symbol` isn't used here, since the whitespace matters in this case

-- | an alias for `symbol`. Intended to be used with commmas, parens, brackets and braces (i.e. punctuation that can't be used in operators)
punctuation :: ParserM m => Text -> m ()
punctuation = void . symbol

{- | parses a keyword, i.e. a symbol not followed by an alphanum character
it is assumed that `kw` appears in the `keywords` list
-}
keyword :: ParserM m => Text -> m ()
keyword kw = label (toString kw) $ try $ lexeme $ string kw *> notFollowedBy (satisfy isIdentifierChar)

-- | an identifier that doesn't start with an uppercase letter
termName' :: ParserM m => m Text
termName' = do
    void $ lookAhead (satisfy $ not . isUpperCase)
    void $ lookAhead (anySingleBut '_') <|> fail "unexpected wildcard"
    lexeme identifier

-- | an identifier that doesn't start with a lowercase letter or a parenthesised operator
termName :: ParserM m => m SimpleName
termName = try (parens someOperator) <|> mkName termName'

{- | a termName that starts with an underscore
note: the current implementation forbids `_1`, `_1abc`, etc. That may be undesired
-}
wildcard :: ParserM m => m ()
wildcard = single '_' *> void identifier

{- | an identifier that starts with an uppercase letter
this is not a lexeme
-}
typeName' :: ParserM m => m Text
typeName' = do
    void $ lookAhead (satisfy isUpperCase)
    identifier

{- | an identifier that starts with an uppercase letter
unlike `typeName'`, this /is/ a lexeme
-}
typeName :: ParserM m => m SimpleName
typeName = lexeme $ mkName typeName'

{- | a value constructor name
this is not a lexeme
-}
constructorName :: ParserM m => m SimpleName
constructorName = mkName typeName'

-- | an identifier that starts with a ' and a lowercase letter, i.e. 'acc
typeVariable :: ParserM m => m SimpleName
typeVariable = try $ mkName $ liftA2 Text.cons (single '\'') termName'

{- | an identifier that starts with a ' and an uppercase letter, i.e. 'Some
this is not a lexeme
-}
variantConstructor :: ParserM m => m SimpleName
variantConstructor = try $ mkName $ liftA2 Text.cons (single '\'') typeName'

{- | a helper for other identifier parsers
note that it's not a lexeme, i.e. it doesn't consume trailing whitespace
-}
identifier :: ParserM m => m Text
identifier = try do
    ident <- Text.cons <$> (letterChar <|> char '_') <*> takeWhileP (Just "identifier") isIdentifierChar
    when (ident `Set.member` keywords) (fail $ "unexpected keyword '" <> toString ident <> "'")
    pure ident

{- | a record lens, i.e. .field.otherField.thirdField
Chances are, this parser will only ever be used with E.RecordLens
-}
recordLens :: ParserM m => m (NonEmpty SimpleName)
recordLens = label "record lens" $ lexeme $ single '.' *> mkName identifier `NE.sepBy1` single '.'

-- for anybody wondering, `empty` is *not* a noop parser
intLiteral :: ParserM m => m Literal
intLiteral = label "int literal" $ try $ lexeme $ located $ fmap IntLiteral $ L.signed pass L.decimal

-- todo: handle escape sequences and interpolation
textLiteral :: ParserM m => m Literal
textLiteral =
    label "text literal" $
        located $
            fmap TextLiteral $
                between (symbol "\"") (symbol "\"") $
                    takeWhileP (Just "text literal body") (/= '"')

charLiteral :: ParserM m => m Literal
charLiteral = label "char literal" $ try $ located $ fmap CharLiteral $ one <$> between (single '\'') (symbol "'") anySingle

-- | any literal
literal :: ParserM m => m Literal
literal = choice [intLiteral, textLiteral, charLiteral]

operator :: ParserM m => Text -> m Loc
operator sym = label "operator" $ lexeme $ withLoc' const $ string sym *> notFollowedBy (satisfy isOperatorChar)

someOperator :: ParserM m => m SimpleName
someOperator = lexeme $ mkName $ try do
    op <- takeWhile1P (Just "operator") isOperatorChar
    guard (not $ op `Set.member` specialSymbols)
    pure op

-- (+), (<$>), etc.
operatorInParens :: ParserM m => m SimpleName
operatorInParens = try $ parens someOperator

isOperatorChar :: Char -> Bool
isOperatorChar = (`elem` ("+-*/%^=><&.~!?|@#$:" :: String))

isIdentifierChar :: Char -> Bool
isIdentifierChar c = isAlphaNum c || c == '_' || c == '\''

{- todo: it might be a good idea to ignore strict newlines when inside the brackets
i.e. that would allow
> stuff = [
>   x,
>   y,
>   z,
> ]
the indentation inside the list is optional as well
using anythinging indentation-sensitve, i.e. do notation, reintroduces strict newlines
> otherStuff = [
>   x,
>   do
>     action1
>     action2,
>   y,
> ]
-}
parens, brackets, braces :: ParserM m => m a -> m a
parens = between (punctuation "(") (punctuation ")")
brackets = between (punctuation "[") (punctuation "]")
braces = between (punctuation "{") (punctuation "}")

-- leading commas, trailing commas, anything goes
commaSep :: ParserM m => m a -> m [a]
commaSep p = optional (punctuation ",") *> p `sepEndBy` punctuation ","

{- | parses an AST node with location info
todo: don't include trailing whitespace where possible
-}
withLoc :: ParserM m => m (Loc -> a) -> m a
withLoc p = do
    start <- getSourcePos
    f <- p
    end <- getSourcePos
    let loc = if start == end then Blank else locFromSourcePos start end
    pure $ f loc

withLoc' :: ParserM m => (Loc -> a -> b) -> m a -> m b
withLoc' f p = withLoc $ flip f <$> p

located :: ParserM m => m a -> m (Located a)
located p = withLoc $ flip Located <$> p

mkName :: ParserM m => m Text -> m SimpleName
mkName = located . fmap Name'

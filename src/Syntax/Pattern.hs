module Syntax.Pattern (Pattern (..)) where

import Relude
import Syntax.Row

data Pattern n
    = Var n
    | Constructor n [Pattern n]
    | Variant OpenName (Pattern n)
    | Record (Row (Pattern n))
    | List [Pattern n]
    | IntLiteral Int
    | TextLiteral Text
    | CharLiteral Text
    deriving (Show, Eq, Functor, Foldable, Traversable)

-- note that the Traversable instance generally
-- doesn't do what you want
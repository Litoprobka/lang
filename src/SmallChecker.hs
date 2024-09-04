{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

module SmallChecker where

import Control.Monad (foldM)
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HashSet
import Data.Text qualified as Text
import Relude hiding (Type)

-- a disambiguated name
data Name = Name Text Int deriving (Show, Eq, Generic, Hashable)
newtype UniVar = UniVar Int
    deriving (Show, Eq)
    deriving newtype (Hashable)
newtype Skolem = Skolem Name
    deriving (Show, Eq)
    deriving newtype (Hashable)
newtype Scope = Scope Int deriving (Show, Eq, Ord)

data Expr
    = EName Name
    | ECon Name
    | EApp Expr Expr
    | ELambda Pattern Expr
    | EAnn Expr Type
    deriving (Show, Eq)

data Pattern
    = PVar Name
    | PCon Name [Pattern]
    deriving (Show, Eq)

data Type
    = TVar Name
    | TName Name
    | TSkolem Skolem
    | TUniVar UniVar -- unification variable
    | TForall Name Type -- ∀a. body
    | TExists Name Type -- ∃a. body
    | TApp Type Type
    | TFn Type Type
    deriving (Show, Eq)

-- а type whose outer constructor is monomorphic
data MonoLayer
    = MName Name
    | MSkolem Skolem
    | MUniVar UniVar
    | MApp Type Type
    | MFn Type Type
    deriving (Show, Eq)

newtype TypeError = TypeError Text deriving (Show)

data InfState = InfState
    { nextUniVarId :: Int
    , nextSkolemId :: Int
    , nextTypeVar :: Name
    , currentScope :: Scope
    , sigs :: HashMap Name Type -- known bindings and type constructors
    , vars :: HashMap UniVar (Either Scope Type) -- contains either the scope of an unsolved var or a type
    }

type InfMonad = ExceptT TypeError (State InfState)

pretty :: Type -> Text
pretty = go False
  where
    go parens = \case
        TVar (Name name n) -> name <> postfix n "#"
        TName (Name name n) -> name <> postfix n "#"
        TSkolem (Skolem (Name name n)) -> name <> "?" <> postfix n ""
        TUniVar (UniVar n) -> "#" <> show n
        TForall name body -> mkParens $ "∀" <> go parens (TVar name) <> ". " <> go parens body
        TExists name body -> mkParens $ "∃" <> go parens (TVar name) <> ". " <> go parens body
        TApp lhs rhs -> mkParens $ go False lhs <> " " <> go True rhs -- at some point I'm gonna need proper precedence rules
        TFn from to -> mkParens $ go True from <> " -> " <> go False to
      where
        mkParens txt
            | parens = "(" <> txt <> ")"
            | otherwise = txt

    postfix 0 _ = ""
    postfix n sym = sym <> show n

-- helpers

runDefault :: InfMonad a -> Either TypeError a
runDefault = run defaultEnv

run :: HashMap Name Type -> InfMonad a -> Either TypeError a
run env =
    evaluatingState
        InfState
            { nextUniVarId = 0
            , nextSkolemId = 0
            , nextTypeVar = Name "a" 0
            , currentScope = Scope 0
            , sigs = env
            , vars = HashMap.empty
            }
        . runExceptT

defaultEnv :: HashMap Name Type
defaultEnv =
    HashMap.fromList
        [ (Name "()" 0, TName $ Name "()" 0)
        , (Name "Nothing" 0, TForall a' $ TName (Name "Maybe" 0) `TApp` a)
        , (Name "Just" 0, TForall a' $ a `TFn` (TName (Name "Maybe" 0) `TApp` a))
        ]
  where
    a' = Name "a" 0
    a = TVar a'

-- b' = Name "b" 0
-- b = TVar b'

inferIO :: Expr -> IO ()
inferIO expr = case runDefault $ fmap pretty . normalise =<< infer expr of
    Left (TypeError err) -> putTextLn err
    Right txt -> putTextLn txt

typeError :: Text -> InfMonad a
typeError err = ExceptT $ pure (Left $ TypeError err)

freshUniVar :: InfMonad UniVar
freshUniVar = do
    -- and this is where I wish I had lens
    var <- UniVar <$> gets (.nextUniVarId) <* modify \s -> s{nextUniVarId = succ s.nextUniVarId}
    scope <- gets (.currentScope)
    modify \s -> s{vars = HashMap.insert var (Left scope) s.vars}
    pure var

freshSkolem :: Name -> InfMonad Skolem
freshSkolem (Name name _) = Skolem . Name name <$> gets (.nextSkolemId) <* modify \s -> s{nextSkolemId = succ s.nextSkolemId}

freshTypeVar :: InfMonad Name
freshTypeVar = gets (.nextTypeVar) <* modify \s -> s{nextTypeVar = inc s.nextTypeVar}
  where
    inc (Name name n)
        | Text.head name < 'z' = Name (Text.singleton $ succ $ Text.head name) n
        | otherwise = Name "a" (succ n)

lookupUniVar :: UniVar -> InfMonad (Either Scope Type)
lookupUniVar uni = maybe (typeError $ "missing univar " <> pretty (TUniVar uni)) pure . HashMap.lookup uni =<< gets (.vars)

withUniVar :: UniVar -> (Type -> InfMonad a) -> InfMonad ()
withUniVar uni f =
    lookupUniVar uni >>= \case
        Left _ -> pass
        Right ty -> void $ f ty

solveUniVar, overrideUniVar :: UniVar -> Type -> InfMonad ()
solveUniVar = alterUniVar False
overrideUniVar = alterUniVar True

data SelfRef = Direct | Indirect

alterUniVar :: Bool -> UniVar -> Type -> InfMonad ()
alterUniVar override uni ty = do
    -- here comes the magic. If the new type contains other univars, we change their scope
    lookupUniVar uni >>= \case
        Right _ | not override -> typeError $ "Internal error (probably a bug): attempted to solve a solved univar " <> pretty (TUniVar uni)
        Right _ -> pass
        Left scope -> rescope scope ty
    modify \s -> s{vars = HashMap.insert uni (Right ty) s.vars}
    cycleCheck (Direct, HashSet.empty) ty
  where
    foldUniVars :: (UniVar -> InfMonad ()) -> Type -> InfMonad ()
    foldUniVars action = \case
        TUniVar v -> action v >> lookupUniVar v >>= either (const pass) (foldUniVars action)
        TForall _ body -> foldUniVars action body
        TExists _ body -> foldUniVars action body
        TApp lhs rhs -> foldUniVars action lhs >> foldUniVars action rhs
        TFn from to -> foldUniVars action from >> foldUniVars action to
        TVar _ -> pass
        TName _ -> pass
        TSkolem _ -> pass

    -- resolves direct univar cycles (i.e. a ~ b, b ~ c, c ~ a) to skolems
    -- errors out on indirect cycles (i.e. a ~ Maybe a)
    cycleCheck (selfRefType, acc) = \case
        TUniVar uni2 | HashSet.member uni2 acc -> case selfRefType of
            Direct -> do
                skolem <- freshSkolem $ Name "q" 0
                modify \s -> s{vars = HashMap.insert uni2 (Right $ TSkolem skolem) s.vars}
            Indirect -> typeError "self-referential type"
        TUniVar uni2 -> withUniVar uni2 $ cycleCheck (selfRefType, HashSet.insert uni2 acc)
        TForall _ body -> cycleCheck (Indirect, acc) body
        TExists _ body -> cycleCheck (Indirect, acc) body
        TFn from to -> cycleCheck (Indirect, acc) from >> cycleCheck (Indirect, acc) to
        TApp lhs rhs -> cycleCheck (Indirect, acc) lhs >> cycleCheck (Indirect, acc) rhs
        TVar _ -> pass
        TName _ -> pass
        TSkolem _ -> pass

    rescope scope = foldUniVars \v -> lookupUniVar v >>= either (rescopeVar v scope) (const pass)
    rescopeVar v scope oldScope = modify \s -> s{vars = HashMap.insert v (Left $ min oldScope scope) s.vars}

lookupSig :: Name -> InfMonad Type
lookupSig name = maybe (typeError "unbound name???") pure =<< gets (HashMap.lookup name . (.sigs))

updateSig :: Name -> Type -> InfMonad ()
updateSig name ty = modify \s -> s{sigs = HashMap.insert name ty s.sigs}

-- | run the given action and discard signature updates
scoped :: InfMonad a -> InfMonad a
scoped action = do
    sigs <- gets (.sigs)
    action <* modify \s -> s{sigs}

-- turns out it's tricky to get this function right.
-- just taking all of the new univars and turning them into type vars is not enough,
-- since a univar may be produced when specifying a univar from parent scope (i.e. `#a` to `#b -> #c`)
forallScope :: InfMonad Type -> InfMonad Type
forallScope action = do
    start <- gets (.nextUniVarId)
    modify \s@InfState{currentScope = Scope n} -> s{currentScope = Scope $ succ n}
    out <- action
    modify \s@InfState{currentScope = Scope n} -> s{currentScope = Scope $ pred n}
    end <- pred <$> gets (.nextUniVarId)
    outerScope <- gets (.currentScope)
    -- I'm not sure whether it's sound to convert all skolems in scope
    -- skolems may need a scope approach similar to univars
    -- skolemsToExists =<<
    foldM (applyVar outerScope) out (UniVar <$> [start .. end])
  where
    applyVar outerScope bodyTy uni =
        lookupUniVar uni >>= \case
            Right ty -> do
                substituteTy (TUniVar uni) ty bodyTy
            Left scope | scope > outerScope && isRelevant uni bodyTy -> do
                tyVar <- freshTypeVar
                solveUniVar uni (TVar tyVar)
                pure $ TForall tyVar bodyTy
            Left _ -> pure bodyTy
    isRelevant uni = \case
        TUniVar v | v == uni -> True
        TUniVar _ -> False
        TForall _ body' -> isRelevant uni body'
        TExists _ body' -> isRelevant uni body'
        TFn from to -> isRelevant uni from || isRelevant uni to
        TApp lhs rhs -> isRelevant uni lhs || isRelevant uni rhs
        TName _ -> False
        TVar _ -> False
        TSkolem _ -> False

--

data Variance = In | Out | Inv

{- | Unwraps a polytype until a simple constructor is encountered
-- >> mono Out (forall a. a -> a)
-- ?a -> ?a
-- >> mono In (forall a. a -> a)
-- #a -> #a
-- >> mono Out (forall a. forall b. a -> b -> a)
-- ?a -> ?b -> ?a
-- >> mono Out (forall a. (forall b. b -> a) -> a)
-- (forall b. b -> ?a) -> ?a
-}
mono :: Variance -> Type -> InfMonad MonoLayer
mono variance = \case
    v@TVar{} -> typeError $ "unbound type variable " <> pretty v
    TName name -> pure $ MName name
    TSkolem skolem -> pure $ MSkolem skolem
    TUniVar uni -> pure $ MUniVar uni
    TApp lhs rhs -> pure $ MApp lhs rhs
    TFn from to -> pure $ MFn from to
    TForall var body -> mono variance =<< substitute variance var body
    TExists var body -> mono variance =<< substitute (flipVariance variance) var body
  where
    flipVariance = \case
        In -> Out
        Out -> In
        Inv -> Inv

unMono :: MonoLayer -> Type
unMono = \case
    MName name -> TName name
    MSkolem skolem -> TSkolem skolem
    MUniVar uniVar -> TUniVar uniVar
    MApp lhs rhs -> TApp lhs rhs
    MFn from to -> TFn from to

substitute :: Variance -> Name -> Type -> InfMonad Type
substitute variance var ty = do
    someVar <- freshSomething var variance
    go someVar ty
  where
    go replacement = \case
        TVar v | v == var -> pure replacement
        TVar name -> pure $ TVar name
        TUniVar uni -> TUniVar uni <$ withUniVar uni (go replacement >=> overrideUniVar uni)
        TForall v body
            | v /= var -> TForall v <$> go replacement body
            | otherwise -> pure $ TForall v body
        TExists v body
            | v /= var -> TExists v <$> go replacement body
            | otherwise -> pure $ TExists v body
        TFn from to -> TFn <$> go replacement from <*> go replacement to
        TApp lhs rhs -> TApp <$> go replacement lhs <*> go replacement rhs
        name@TName{} -> pure name
        skolem@TSkolem{} -> pure skolem

    -- freshUniVar or freshSkolem, depending on variance
    -- should it be the other way around?
    --
    -- out: forall a. Int -> a
    -- in: forall a. a -> Int
    freshSomething name = \case
        In -> TUniVar <$> freshUniVar
        Out -> TSkolem <$> freshSkolem name
        Inv -> TSkolem <$> freshSkolem name

-- `substituteTy` shouldn't be used for type vars, because it fails in cases like `forall a. (forall a. body)`
-- normally those are removed by name resolution, but they may still occur when checking, say `f (f x)`
substituteTy :: Type -> Type -> Type -> InfMonad Type
substituteTy from to = go
  where
    go = \case
        ty | ty == from -> pure to
        TUniVar uni -> TUniVar uni <$ withUniVar uni (go >=> overrideUniVar uni)
        TForall v body -> TForall v <$> go body
        TExists v body -> TExists v <$> go body
        TFn in' out' -> TFn <$> go in' <*> go out'
        TApp lhs rhs -> TApp <$> go lhs <*> go rhs
        v@TVar{} -> pure v
        skolem@TSkolem{} -> pure skolem
        name@TName{} -> pure name

-- gets rid of all univars
normalise :: Type -> InfMonad Type
normalise = uniVarsToForall >=> skolemsToExists >=> go
  where
    go = \case
        TUniVar uni ->
            lookupUniVar uni >>= \case
                Left _ -> typeError $ "dangling univar " <> pretty (TUniVar uni)
                Right body -> go body
        TForall var body -> TForall var <$> go body
        TExists var body -> TExists var <$> go body
        TFn from to -> TFn <$> go from <*> go to
        TApp lhs rhs -> TApp <$> go lhs <*> go rhs
        v@TVar{} -> pure v
        name@TName{} -> pure name
        skolem@TSkolem{} -> typeError $ "skolem " <> pretty skolem <> " remains in code"

    -- this is an alternative to forallScope that's only suitable at the top level
    uniVarsToForall ty = uncurry (foldr TForall) <$> uniGo HashSet.empty ty
    uniGo acc = \case
        TUniVar uni ->
            lookupUniVar uni >>= \case
                Left _ -> do
                    tyVar <- freshTypeVar
                    solveUniVar uni (TVar tyVar)
                    pure (TVar tyVar, HashSet.insert tyVar acc)
                Right body -> first (const $ TUniVar uni) <$> uniGo acc body
        TForall var body -> first (TForall var) <$> uniGo acc body
        TExists var body -> first (TExists var) <$> uniGo acc body
        TFn from to -> do
            (from', acc') <- uniGo acc from
            (to', acc'') <- uniGo acc' to
            pure (TFn from' to', acc'')
        TApp lhs rhs -> do
            (lhs', acc') <- uniGo acc lhs
            (rhs', acc'') <- uniGo acc' rhs
            pure (TApp lhs' rhs', acc'')
        v@TVar{} -> pure (v, acc)
        name@TName{} -> pure (name, acc)
        skolem@TSkolem{} -> pure (skolem, acc)

data VarType = Forall | Existential

-- finds all type parameters used in a type and creates corresponding forall clauses
-- doesn't work with type vars, because the intended use case is pre-processing user-supplied types
inferTypeVars :: Type -> Type
inferTypeVars = uncurry (foldr TForall) . second snd . go (HashSet.empty, HashSet.empty)
  where
    go acc@(supplied, new) = \case
        TVar var
            | not $ HashSet.member var supplied -> (TVar var, (supplied, HashSet.insert var new))
            | otherwise -> (TVar var, acc)
        TForall var body -> first (TForall var) $ go (HashSet.insert var supplied, new) body
        TExists var body -> first (TExists var) $ go (HashSet.insert var supplied, new) body
        TFn from to ->
            let (from', acc') = go acc from
                (to', acc'') = go acc' to
             in (TFn from' to', acc'')
        TApp lhs rhs ->
            let (lhs', acc') = go acc lhs
                (rhs', acc'') = go acc' rhs
             in (TApp lhs' rhs', acc'')
        uni@TUniVar{} -> (uni, acc)
        skolem@TSkolem{} -> (skolem, acc)
        name@TName{} -> (name, acc)

--

subtype :: Type -> Type -> InfMonad ()
subtype lhsTy rhsTy = join $ match <$> mono In lhsTy <*> mono Out rhsTy
  where
    match = \cases
        lhs rhs | lhs == rhs -> pass -- simple cases, i.e. two type constructors, two univars or two exvars
        (MFn inl outl) (MFn inr outr) -> do
            subtype inr inl
            subtype outl outr
        (MApp lhs rhs) (MApp lhs' rhs') -> do
            -- note that we assume the same variance for all type parameters
            -- some kind of kind system is needed to track variance and prevent stuff like `Maybe a b`
            subtype lhs lhs'
            subtype rhs rhs'
        lhs (MUniVar uni) -> solveOr (unMono lhs) (subtype $ unMono lhs) uni
        (MUniVar uni) rhs -> solveOr (unMono rhs) (`subtype` unMono rhs) uni
        lhs rhs -> typeError $ pretty (unMono lhs) <> " is not a subtype of " <> pretty (unMono rhs)

    -- turns out it's different enough from `withUniVar`
    solveOr :: Type -> (Type -> InfMonad ()) -> UniVar -> InfMonad ()
    solveOr solveWith whenSolved uni = lookupUniVar uni >>= either (const $ solveUniVar uni solveWith) whenSolved

-- these two functions have the same problem as the old `forallScope` - they capture skolems from an outer scope
-- it's not clear whether anything should be done about them
-- the only problem I can see is a univar unifying with a type var from an inner scope, but I'm not sure how would that happen
--
-- it is still safe to use these at the top-level, however
skolemsToExists, skolemsToForall :: Type -> InfMonad Type
(skolemsToExists, skolemsToForall) = (skolemsToExists', skolemsToForall')
  where
    -- ∃a. a -> a <: b
    -- ?a -> ?a <: b
    -- b ~ ∃a. a -> a
    skolemsToExists' ty = uncurry (foldr TExists) <$> go HashMap.empty ty
    -- b <: ∀a. a -> a
    -- b <: ?a -> ?a
    -- b ~ ∀a. a -> a
    skolemsToForall' ty = uncurry (foldr TForall) <$> go HashMap.empty ty

    go acc = \case
        TSkolem skolem -> case HashMap.lookup skolem acc of
            Just tyVar -> pure (TVar tyVar, acc)
            Nothing -> do
                tyVar <- freshTypeVar
                pure (TVar tyVar, HashMap.insert skolem tyVar acc)
        TUniVar uni -> pure (TUniVar uni, acc) -- I'm not sure what to do with a univar boundary
        TForall var body -> first (TForall var) <$> go acc body
        TExists var body -> first (TExists var) <$> go acc body
        TFn from to -> do
            (from', acc') <- go acc from
            (to', acc'') <- go acc' to
            pure (TFn from' to', acc'')
        TApp lhs rhs -> do
            (lhs', acc') <- go acc lhs
            (rhs', acc'') <- go acc' rhs
            pure (TApp lhs' rhs', acc'')
        v@TVar{} -> pure (v, acc)
        name@TName{} -> pure (name, acc)

check :: Expr -> Type -> InfMonad ()
check e = mono Out >=> match e
  where
    match = \cases
        (EName name) ty -> do
            ty' <- lookupSig name
            subtype ty' $ unMono ty
        (ECon name) ty -> do
            ty' <- lookupSig name
            subtype ty' $ unMono ty
        (ELambda arg body) (MFn from to) -> scoped do
            -- `checkPattern` updates signatures of all mentioned variables
            checkPattern arg from
            check body to
        (EAnn expr ty') ty -> do
            subtype ty' $ unMono ty
            check expr ty'
        expr ty -> do
            ty' <- infer expr
            subtype ty' $ unMono ty

checkPattern :: Pattern -> Type -> InfMonad ()
checkPattern = \cases
    (PVar name) ty -> updateSig name ty
    -- it's not clear whether value constructors need a separate rule
    pat ty -> do
        ty' <- inferPattern pat
        subtype ty' ty

infer :: Expr -> InfMonad Type
infer = \case
    EName name -> lookupSig name
    ECon name -> lookupSig name
    EApp f x -> do
        fTy <- infer f
        inferApp fTy x
    ELambda arg body -> {-forallScope-} do
        argTy <- inferPattern arg
        TFn argTy <$> infer body
    EAnn expr ty -> ty <$ check expr ty

inferPattern :: Pattern -> InfMonad Type
inferPattern = \case
    (PVar name) -> do
        uni <- TUniVar <$> freshUniVar
        updateSig name uni
        pure uni
    p@(PCon name args) -> do
        (resultType, argTypes) <- conArgTypes name
        unless (length argTypes == length args) $ typeError $ "incorrect arg count in pattern " <> show p
        zipWithM_ checkPattern args argTypes
        pure resultType
  where
    -- conArgTypes and the zipM may be unified into a single function
    conArgTypes = lookupSig >=> go
    go =
        mono In >=> \case
            MFn arg rest -> second (arg :) <$> go rest
            -- univars should never appear as the rightmost argument of a value constructor type
            -- i.e. types of value constructors have the shape `a -> b -> c -> d -> ConcreteType a b c d`
            --
            -- solved univars cannot appear here either, since `lookupSig` on a pattern returns a type with no univars
            MUniVar uni -> typeError $ "unexpected univar " <> pretty (TUniVar uni) <> " in a constructor type"
            -- this kind of repetition is necessary to retain missing pattern warnings
            MName name -> pure (TName name, [])
            MApp lhs rhs -> pure (TApp lhs rhs, [])
            MSkolem skolem -> pure (TSkolem skolem, [])

inferApp :: Type -> Expr -> InfMonad Type
inferApp fTy arg =
    mono In fTy >>= \case
        MUniVar v -> do
            from <- infer arg
            to <- freshUniVar
            lookupUniVar v >>= \case
                Left _ -> do
                    solveUniVar v $ TFn from (TUniVar to)
                    pure $ TUniVar to
                Right newTy -> inferApp newTy arg
        MFn from to -> to <$ check arg from
        _ -> typeError $ pretty fTy <> " is not a function type"

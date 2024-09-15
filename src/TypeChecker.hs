{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

module TypeChecker (
    run,
    runWithFinalEnv,
    infer,
    inferPattern,
    check,
    checkPattern,
    inferTypeVars,
    normalise,
    Builtins (..),
    InfState (..),
    TypeError (..),
    InfEffs,
    typecheck,
) where

import CheckerTypes
import Control.Monad (foldM)
import Data.Foldable1 (foldlM1, foldr1)
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HashSet
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as Text
import Data.Traversable (for)
import Effectful
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Effectful.Reader.Static (Reader, asks, runReader, ask)
import Effectful.State.Static.Local (State, get, gets, modify, runState)
import GHC.IsList qualified as IsList
import NameGen
import Prettyprinter (Doc, Pretty, pretty, (<+>))
import Relude hiding (Reader, State, Type, ask, asks, bool, get, gets, modify, put, runReader, runState)
import Syntax
import Syntax.Declaration qualified as D
import Syntax.Expression qualified as E
import Syntax.Pattern qualified as P
import Syntax.Row (ExtRow (..))
import Syntax.Row qualified as Row
import Syntax.Type qualified as T

type Expr = Expression Name
type Pattern' = Pattern Name

type Type = Type' Name

-- а type whose outer constructor is monomorphic
data MonoLayer
    = MName Name
    | MSkolem Skolem
    | MUniVar UniVar
    | MApp Type Type
    | MFn Type Type
    | MVariant (ExtRow Type)
    | MRecord (ExtRow Type)
    deriving (Show, Eq)

newtype TypeError = TypeError (Doc ()) deriving (Show)

data Builtins a = Builtins
    { bool :: a
    , list :: a
    , int :: a
    , nat :: a
    , text :: a
    , char :: a
    , lens :: a
    , subtypeRelations :: [(a, a)]
    }
    deriving (Show, Functor, Foldable, Traversable)

data InfState = InfState
    { nextUniVarId :: Int
    , nextTypeVar :: Char
    , currentScope :: Scope
    , sigs :: HashMap Name Type -- known bindings and type constructors
    , vars :: HashMap UniVar (Either Scope Type) -- contains either the scope of an unsolved var or a type
    }
    deriving (Show)

type InfEffs es = (NameGen :> es, State InfState :> es, Error TypeError :> es, Reader (Builtins Name) :> es)

instance Pretty MonoLayer where
    pretty = pretty . unMono

-- helpers

typecheck
    :: NameGen :> es
    => HashMap Name Type -- imports
    -> Builtins Name
    -> [Declaration Name]
    -> Eff es (Either TypeError (HashMap Name Type))
typecheck env builtins decls = run env builtins $ traverse normalise =<< inferDecls decls

run
    :: HashMap Name Type
    -> Builtins Name
    -> Eff (Error TypeError : Reader (Builtins Name) : State InfState : es) a
    -> Eff es (Either TypeError a)
run env builtins = fmap fst . runWithFinalEnv env builtins

runWithFinalEnv
    :: HashMap Name Type
    -> Builtins Name
    -> Eff (Error TypeError : Reader (Builtins Name) : State InfState : es) a
    -> Eff es (Either TypeError a, InfState)
runWithFinalEnv env builtins = do
    runState
        InfState
            { nextUniVarId = 0
            , nextTypeVar = 'a'
            , currentScope = Scope 0
            , sigs = env
            , vars = HashMap.empty
            }
        . runReader builtins
        . runErrorNoCallStack

typeError :: InfEffs es => Doc () -> Eff es a
typeError err = throwError $ TypeError err

freshUniVar :: InfEffs es => Eff es (Type' n)
freshUniVar = do
    -- and this is where I wish I had lens
    var <- UniVar <$> gets @InfState (.nextUniVarId) <* modify @InfState \s -> s{nextUniVarId = succ s.nextUniVarId}
    scope <- gets @InfState (.currentScope)
    modify \s -> s{vars = HashMap.insert var (Left scope) s.vars}
    pure $ T.UniVar var

freshSkolem :: InfEffs es => Name -> Eff es Type
freshSkolem (Name name _) = T.Skolem . Skolem <$> freshName name

freshTypeVar :: InfEffs es => Eff es Name
freshTypeVar = do
    id' <- freshId
    letter <- gets @InfState (.nextTypeVar) <* modify \s -> s{nextTypeVar = cycleChar s.nextTypeVar}
    pure $ Name (Text.singleton letter) id'
  where
    cycleChar 'z' = 'a'
    cycleChar c = succ c

lookupUniVar :: InfEffs es => UniVar -> Eff es (Either Scope Type)
lookupUniVar uni = maybe (typeError $ "missing univar " <> pretty uni) pure . HashMap.lookup uni =<< gets @InfState (.vars)

withUniVar :: InfEffs es => UniVar -> (Type -> Eff es a) -> Eff es ()
withUniVar uni f =
    lookupUniVar uni >>= \case
        Left _ -> pass
        Right ty -> void $ f ty

solveUniVar, overrideUniVar :: InfEffs es => UniVar -> Type -> Eff es ()
solveUniVar = alterUniVar False
overrideUniVar = alterUniVar True

data SelfRef = Direct | Indirect

alterUniVar :: InfEffs es => Bool -> UniVar -> Type -> Eff es ()
alterUniVar override uni ty = do
    -- here comes the magic. If the new type contains other univars, we change their scope
    lookupUniVar uni >>= \case
        Right _ | not override -> typeError $ "Internal error (probably a bug): attempted to solve a solved univar " <> pretty uni
        Right _ -> pass
        Left scope -> rescope scope ty
    modify \s -> s{vars = HashMap.insert uni (Right ty) s.vars}
    cycleCheck (Direct, HashSet.empty) ty
  where
    foldUniVars :: InfEffs es => (UniVar -> Eff es ()) -> Type -> Eff es ()
    foldUniVars action = \case
        T.UniVar v -> action v >> lookupUniVar v >>= either (const pass) (foldUniVars action)
        T.Forall _ body -> foldUniVars action body
        T.Exists _ body -> foldUniVars action body
        T.Application lhs rhs -> foldUniVars action lhs >> foldUniVars action rhs
        T.Function from to -> foldUniVars action from >> foldUniVars action to
        T.Variant row -> traverse_ (foldUniVars action) row
        T.Record row -> traverse_ (foldUniVars action) row
        T.Var _ -> pass
        T.Name _ -> pass
        T.Skolem _ -> pass

    -- resolves direct univar cycles (i.e. a ~ b, b ~ c, c ~ a) to skolems
    -- errors out on indirect cycles (i.e. a ~ Maybe a)
    cycleCheck (selfRefType, acc) = \case
        T.UniVar uni2 | HashSet.member uni2 acc -> case selfRefType of
            Direct -> do
                -- todo: freshSkolem should take a textual name
                skolem <- freshSkolem $ Name "q" (Id 0)
                modify \s -> s{vars = HashMap.insert uni2 (Right skolem) s.vars}
            Indirect -> typeError "self-referential type"
        T.UniVar uni2 -> withUniVar uni2 $ cycleCheck (selfRefType, HashSet.insert uni2 acc)
        T.Forall _ body -> cycleCheck (Indirect, acc) body
        T.Exists _ body -> cycleCheck (Indirect, acc) body
        T.Function from to -> cycleCheck (Indirect, acc) from >> cycleCheck (Indirect, acc) to
        T.Application lhs rhs -> cycleCheck (Indirect, acc) lhs >> cycleCheck (Indirect, acc) rhs
        T.Variant row -> traverse_ (cycleCheck (Indirect, acc)) row
        T.Record row -> traverse_ (cycleCheck (Indirect, acc)) row
        T.Var _ -> pass
        T.Name _ -> pass
        T.Skolem _ -> pass

    rescope scope = foldUniVars \v -> lookupUniVar v >>= either (rescopeVar v scope) (const pass)
    rescopeVar v scope oldScope = modify \s -> s{vars = HashMap.insert v (Left $ min oldScope scope) s.vars}

lookupSig :: InfEffs es => Name -> Eff es Type
lookupSig name =
    gets @InfState (HashMap.lookup name . (.sigs)) >>= \case
        Just ty -> pure ty
        Nothing -> do
            -- assuming that type checking is performed after name resolution,
            -- all encountered names have to be in scope
            uni <- freshUniVar
            uni <$ updateSig name uni

updateSig :: InfEffs es => Name -> Type -> Eff es ()
updateSig name ty = modify \s -> s{sigs = HashMap.insert name ty s.sigs}

builtin :: Reader (Builtins Name) :> es => (Builtins Name -> a) -> Eff es a
builtin = asks @(Builtins Name)

-- | run the given action and discard signature updates
scoped :: InfEffs es => Eff es a -> Eff es a
scoped action = do
    sigs <- gets @InfState (.sigs)
    action <* modify \s -> s{sigs}

-- turns out it's tricky to get this function right.
-- just taking all of the new univars and turning them into type vars is not enough,
-- since a univar may be produced when specifying a univar from parent scope (i.e. `#a` to `#b -> #c`)
forallScope :: InfEffs es => Eff es Type -> Eff es Type
forallScope action = do
    start <- gets @InfState (.nextUniVarId)
    modify \s@InfState{currentScope = Scope n} -> s{currentScope = Scope $ succ n}
    out <- action
    modify \s@InfState{currentScope = Scope n} -> s{currentScope = Scope $ pred n}
    end <- pred <$> gets @InfState (.nextUniVarId)
    outerScope <- gets @InfState (.currentScope)
    -- I'm not sure whether it's sound to convert all skolems in scope
    -- skolems may need a scope approach similar to univars
    -- skolemsToExists =<<
    foldM (applyVar outerScope) out (UniVar <$> [start .. end])
  where
    applyVar outerScope bodyTy uni =
        lookupUniVar uni >>= \case
            Right ty -> do
                substituteTy (T.UniVar uni) ty bodyTy
            Left scope | scope > outerScope && isRelevant uni bodyTy -> do
                tyVar <- freshTypeVar
                solveUniVar uni (T.Var tyVar)
                pure $ T.Forall tyVar bodyTy
            Left _ -> pure bodyTy
    isRelevant uni = \case
        T.UniVar v -> v == uni
        T.Forall _ body' -> isRelevant uni body'
        T.Exists _ body' -> isRelevant uni body'
        T.Function from to -> isRelevant uni from || isRelevant uni to
        T.Application lhs rhs -> isRelevant uni lhs || isRelevant uni rhs
        T.Variant row -> any (isRelevant uni) row
        T.Record row -> any (isRelevant uni) row
        T.Name _ -> False
        T.Var _ -> False
        T.Skolem _ -> False

--

data Variance = In | Out | Inv

{- | Unwraps a polytype until a simple constructor is encountered

> mono Out (forall a. a -> a)
> -- ?a -> ?a
> mono In (forall a. a -> a)
> -- #a -> #a
> mono Out (forall a. forall b. a -> b -> a)
> -- ?a -> ?b -> ?a
> mono Out (forall a. (forall b. b -> a) -> a)
> -- (forall b. b -> ?a) -> ?a
-}
mono :: InfEffs es => Variance -> Type -> Eff es MonoLayer
mono variance = \case
    v@T.Var{} -> typeError $ "unbound type variable " <> pretty v
    T.Name name -> pure $ MName name
    T.Skolem skolem -> pure $ MSkolem skolem
    T.UniVar uni -> pure $ MUniVar uni
    T.Application lhs rhs -> pure $ MApp lhs rhs
    T.Function from to -> pure $ MFn from to
    T.Variant row -> pure $ MVariant row
    T.Record row -> pure $ MRecord row
    T.Forall var body -> mono variance =<< substitute variance var body
    T.Exists var body -> mono variance =<< substitute (flipVariance variance) var body
  where
    flipVariance = \case
        In -> Out
        Out -> In
        Inv -> Inv

unMono :: MonoLayer -> Type
unMono = \case
    MName name -> T.Name name
    MSkolem skolem -> T.Skolem skolem
    MUniVar uniVar -> T.UniVar uniVar
    MApp lhs rhs -> T.Application lhs rhs
    MFn from to -> T.Function from to
    MVariant row -> T.Variant row
    MRecord row -> T.Record row

substitute :: InfEffs es => Variance -> Name -> Type -> Eff es Type
substitute variance var ty = do
    someVar <- freshSomething var variance
    go someVar ty
  where
    go replacement = \case
        T.Var v | v == var -> pure replacement
        T.Var name -> pure $ T.Var name
        T.UniVar uni -> T.UniVar uni <$ withUniVar uni (go replacement >=> overrideUniVar uni)
        T.Forall v body
            | v /= var -> T.Forall v <$> go replacement body
            | otherwise -> pure $ T.Forall v body
        T.Exists v body
            | v /= var -> T.Exists v <$> go replacement body
            | otherwise -> pure $ T.Exists v body
        T.Function from to -> T.Function <$> go replacement from <*> go replacement to
        T.Application lhs rhs -> T.Application <$> go replacement lhs <*> go replacement rhs
        T.Variant row -> T.Variant <$> traverse (go replacement) row
        T.Record row -> T.Record <$> traverse (go replacement) row
        name@T.Name{} -> pure name
        skolem@T.Skolem{} -> pure skolem

    -- freshUniVar or freshSkolem, depending on variance
    -- should it be the other way around?
    --
    -- out: forall a. Int -> a
    -- in: forall a. a -> Int
    freshSomething name = \case
        In -> freshUniVar
        Out -> freshSkolem name
        Inv -> freshSkolem name

-- `substituteTy` shouldn't be used for type vars, because it fails in cases like `forall a. (forall a. body)`
-- normally those are removed by name resolution, but they may still occur when checking, say `f (f x)`
substituteTy :: InfEffs es => Type -> Type -> Type -> Eff es Type
substituteTy from to = go
  where
    go = \case
        ty | ty == from -> pure to
        T.UniVar uni -> T.UniVar uni <$ withUniVar uni (go >=> overrideUniVar uni)
        T.Forall v body -> T.Forall v <$> go body
        T.Exists v body -> T.Exists v <$> go body
        T.Function in' out' -> T.Function <$> go in' <*> go out'
        T.Application lhs rhs -> T.Application <$> go lhs <*> go rhs
        T.Variant row -> T.Variant <$> traverse go row
        T.Record row -> T.Record <$> traverse go row
        v@T.Var{} -> pure v
        skolem@T.Skolem{} -> pure skolem
        name@T.Name{} -> pure name

-- gets rid of all univars
normalise :: InfEffs es => Type -> Eff es Type
normalise = uniVarsToForall >=> skolemsToExists >=> go
  where
    go = \case
        T.UniVar uni ->
            lookupUniVar uni >>= \case
                Left _ -> typeError $ "dangling univar " <> pretty uni
                Right body -> go body
        T.Forall var body -> T.Forall var <$> go body
        T.Exists var body -> T.Exists var <$> go body
        T.Function from to -> T.Function <$> go from <*> go to
        T.Application lhs rhs -> T.Application <$> go lhs <*> go rhs
        T.Variant row -> T.Variant <$> traverse go row
        T.Record row -> T.Record <$> traverse go row
        v@T.Var{} -> pure v
        name@T.Name{} -> pure name
        skolem@T.Skolem{} -> typeError $ "skolem " <> pretty skolem <> " remains in code"

    -- this is an alternative to forallScope that's only suitable at the top level
    -- it also compresses any records found along the way, because I don't feel like
    -- making that a different pass, and `compress` uses `mono` under the hood, which
    -- means that it has to be run early
    uniVarsToForall ty = uncurry (foldr T.Forall) <$> runState HashSet.empty (uniGo ty)
    uniGo :: InfEffs es => Type -> Eff (State (HashSet Name) : es) Type
    uniGo = \case
        T.UniVar uni ->
            lookupUniVar uni >>= \case
                Left _ -> do
                    tyVar <- freshTypeVar
                    solveUniVar uni (T.Var tyVar)
                    modify $ HashSet.insert tyVar
                    pure $ T.Var tyVar
                Right body -> T.UniVar uni <$ (overrideUniVar uni =<< uniGo body)
        T.Forall var body -> T.Forall var <$> uniGo body
        T.Exists var body -> T.Exists var <$> uniGo body
        T.Function from to -> T.Function <$> uniGo from <*> uniGo to
        T.Application lhs rhs -> T.Application <$> uniGo lhs <*> uniGo rhs
        T.Variant row -> T.Variant <$> (traverse uniGo =<< compress Variant row)
        T.Record row -> T.Record <$> (traverse uniGo =<< compress Record row)
        v@T.Var{} -> pure v
        name@T.Name{} -> pure name
        skolem@T.Skolem{} -> pure skolem

-- these two functions have the same problem as the old `forallScope` - they capture skolems from an outer scope
-- it's not clear whether anything should be done about them
-- the only problem I can see is a univar unifying with a type var from an inner scope, but I'm not sure how would that happen
--
-- it is still safe to use these at the top-level, however
skolemsToExists, skolemsToForall :: forall es. InfEffs es => Type -> Eff es Type
-- ∃a. a -> a <: b
-- ?a -> ?a <: b
-- b ~ ∃a. a -> a
skolemsToExists = replaceSkolems T.Exists
-- b <: ∀a. a -> a
-- b <: ?a -> ?a
-- b ~ ∀a. a -> a
skolemsToForall = replaceSkolems T.Forall

replaceSkolems :: InfEffs es => (Name -> Type -> Type) -> Type -> Eff es Type
replaceSkolems con ty = uncurry (foldr con) <$> runState HashMap.empty (go ty)
  where
    go :: InfEffs es => Type -> Eff (State (HashMap Skolem Name) : es) Type
    go = \case
        T.Skolem skolem ->
            get @(HashMap Skolem Name) >>= \acc -> case HashMap.lookup skolem acc of
                Just tyVar -> pure $ T.Var tyVar
                Nothing -> do
                    tyVar <- freshTypeVar
                    modify $ HashMap.insert skolem tyVar
                    pure $ T.Var tyVar
        T.UniVar uni ->
            lookupUniVar uni >>= \case
                Left _ -> pure $ T.UniVar uni
                Right body -> do
                    body' <- go body
                    overrideUniVar uni body'
                    pure body'
        T.Forall var body -> T.Forall var <$> go body
        T.Exists var body -> T.Exists var <$> go body
        T.Function from to -> T.Function <$> go from <*> go to
        T.Application lhs rhs -> T.Application <$> go lhs <*> go rhs
        T.Record row -> T.Record <$> traverse go row
        T.Variant row -> T.Variant <$> traverse go row
        v@T.Var{} -> pure v
        name@T.Name{} -> pure name

-- what to match
data RecordOrVariant = Record | Variant deriving (Eq)
conOf :: RecordOrVariant -> ExtRow (Type' n) -> Type' n
conOf Record = T.Record
conOf Variant = T.Variant

-- lookup a field in a type, assuming that the type is a row type
-- if a univar is encountered, it's solved to a row type
--
-- I'm not sure how to handle polymorphism here yet, so I'll go
-- with Inv just in case
--
-- Note: repetitive calls of deepLookup on an open row turn it into a chain of singular extensions
-- you should probably call `compress` after that
deepLookup :: InfEffs es => RecordOrVariant -> Row.OpenName -> Type -> Eff es (Maybe Type)
deepLookup whatToMatch k =
    mono Inv >=> \case
        MRecord nextRow
            | whatToMatch == Record -> deepLookup' nextRow
            | otherwise -> pure Nothing
        MVariant nextRow
            | whatToMatch == Variant -> deepLookup' nextRow
            | otherwise -> pure Nothing
        MUniVar uni ->
            lookupUniVar uni >>= \case
                Right ty -> deepLookup whatToMatch k ty
                Left _ -> do
                    fieldType <- freshUniVar
                    rowVar <- freshUniVar
                    let con = conOf whatToMatch
                    solveUniVar uni $ con $ ExtRow (one (k, fieldType)) rowVar
                    pure $ Just fieldType

        -- once again, the cases are listed so that I don't forget to
        -- update them if I ever need to add a new MonoLayer constructor
        -- _ -> pure Nothing
        MSkolem{} -> pure Nothing
        MName{} -> pure Nothing
        MApp{} -> pure Nothing
        MFn{} -> pure Nothing
  where
    deepLookup' :: InfEffs es => ExtRow Type -> Eff es (Maybe Type)
    deepLookup' extRow = case Row.lookup k extRow.row of
        Just v -> pure $ Just v
        Nothing -> case Row.extension extRow of
            Nothing -> pure Nothing
            Just ext -> deepLookup whatToMatch k ext

{- | compresses known row extensions of a row

@{ x : Int | y : Double | z : Char | r } -> { x : Int, y : Double, z : Char | r }@
-}
compress :: InfEffs es => RecordOrVariant -> ExtRow Type -> Eff es (ExtRow Type)
compress _ row@NoExtRow{} = pure row
compress whatToMatch r@(ExtRow row ext) = go ext
  where
    go =
        mono Inv >=> \case
            MRecord nextRow
                | whatToMatch == Record -> Row.extend row <$> go (T.Record nextRow)
                | otherwise -> pure r
            MVariant nextRow
                | whatToMatch == Variant -> Row.extend row <$> go (T.Variant nextRow)
                | otherwise -> pure r
            MUniVar uni ->
                lookupUniVar uni >>= \case
                    Right ty -> go ty
                    Left _ -> pure r
            -- once again, the cases are listed so that I don't forget to
            -- update them if I ever need to add a new MonoLayer constructor
            -- _ -> pure r
            MSkolem{} -> pure r
            MName{} -> pure r
            MApp{} -> pure r
            MFn{} -> pure r

-- first record minus fields that match with the second one
diff :: InfEffs es => RecordOrVariant -> ExtRow Type -> Row Type -> Eff es (ExtRow Type)
diff whatToMatch lhsUncompressed rhs = do
    lhs <- compress whatToMatch lhsUncompressed
    pure $ lhs{row = Row.diff lhs.row rhs}

-- finds all type parameters used in a type and creates corresponding forall clauses
-- doesn't work with type vars (univars?), because the intended use case is pre-processing user-supplied types
inferTypeVars :: Type -> Type
inferTypeVars = uncurry (foldr T.Forall) . second snd . runPureEff . runState (HashSet.empty, HashSet.empty) . go
  where
    go :: Type -> Eff '[State (HashSet Name, HashSet Name)] Type
    go = \case
        T.Var var -> do
            isNew <- not . HashSet.member var <$> gets @(HashSet Name, HashSet Name) snd
            when isNew $ modify @(HashSet Name, HashSet Name) (second $ HashSet.insert var)
            pure $ T.Var var
        T.Forall var body -> modify @(HashSet Name, HashSet Name) (first $ HashSet.insert var) >> T.Forall var <$> go body
        T.Exists var body -> modify @(HashSet Name, HashSet Name) (first $ HashSet.insert var) >> T.Exists var <$> go body
        T.Function from to -> T.Function <$> go from <*> go to
        T.Application lhs rhs -> T.Application <$> go lhs <*> go rhs
        T.Variant row -> T.Variant <$> traverse go row
        T.Record row -> T.Record <$> traverse go row
        uni@T.UniVar{} -> pure uni
        skolem@T.Skolem{} -> pure skolem
        name@T.Name{} -> pure name

-- | check / infer types of a list of declarations that may reference each other
inferDecls :: InfEffs es => [Declaration Name] -> Eff es (HashMap Name Type)
inferDecls decls = do
    let (values, sigs) = foldr getValueDecls ([], []) decls
    traverse_ (uncurry updateSig) sigs
    HashMap.fromList . catMaybes <$> for values \(binding, locals) -> do
        void $ inferDecls locals
        inferBinding binding
  where
    getValueDecls decl (values, sigs) = case decl of
        D.Value binding locals -> ((binding, locals) : values, sigs)
        D.Signature name sig -> (values, (name, sig) : sigs)
        D.Type name vars constrs -> (values, mkConstrSigs name vars constrs ++ sigs)
        D.Alias{} -> (values, sigs)

    mkConstrSigs :: Name -> [Name] -> [(Name, [Type])] -> [(Name, Type)]
    mkConstrSigs name vars constrs =
        second (\conParams -> foldr T.Forall (foldr T.Function (T.Name name) conParams) vars)
            <$> constrs

--

-- finds a "least common denominator" of two types, i.e.
-- @subtype a (supertype a b)@ and @subtype b (supertype a b)@
--
-- this is what you get when you try to preserve polytypes in univars
supertype :: InfEffs es => Type -> Type -> Eff es Type
supertype = \cases
    lhs rhs | lhs == rhs -> pure lhs
    lhs (T.UniVar uni) ->
        lookupUniVar uni >>= \case
            Left _ -> lhs <$ solveUniVar uni lhs
            Right rhs' -> supertype lhs rhs'
    lhs@T.UniVar{} rhs -> supertype rhs lhs
    -- and here comes the interesting part: we get back polymorphism by applying forallScope
    -- a similar function for existentials and skolems is TBD
    lhs rhs -> do
        rels <- builtin (.subtypeRelations)
        forallScope $ join $ match rels <$> mono In lhs <*> mono In rhs
  where
    match rels = \cases
        lhs rhs | lhs == rhs -> pure $ unMono lhs
        (MName lhs) (MName rhs)
            -- for now, it only handles direct subtype/supertype relations
            -- instead, this case should search for a common supertype
            -- if we require subtypeRelations to be transitive, searching
            -- would be as easy as taking all supertypes of lhs and rhs,
            -- taking the intersection and throwing an error if more than
            -- one type matches
            | (lhs, rhs) `elem` rels -> pure $ T.Name rhs
            | (rhs, lhs) `elem` rels -> pure $ T.Name lhs
        (MFn from to) (MFn from' to') -> T.Function <$> supertype from from' <*> supertype to to'
        (MApp lhs rhs) (MApp lhs' rhs') -> T.Application <$> supertype lhs lhs' <*> supertype rhs rhs'
        (MVariant lhs) (MVariant rhs) -> rowCase Variant lhs rhs
        (MRecord lhs) (MRecord rhs) -> rowCase Record lhs rhs
        -- note that a fresh existential (i.e `exists a. a`) *is* a common supertype of any two types
        -- but using that would make type errors more confusing
        -- (i.e. instead of "Int is not a subtype of Char" we would suddenly get existentials everywhere)
        lhs rhs -> typeError $ "cannot unify" <+> pretty lhs <+> "and" <+> pretty rhs

    rowCase whatToMatch lhsUncompressed rhsUncompressed = do
        let con = conOf whatToMatch
        lhs <- compress whatToMatch lhsUncompressed
        rhs <- compress whatToMatch rhsUncompressed
        baseRow <- Row.unionWithM supertype lhs.row rhs.row
        con <$> case (Row.extension lhs, Row.extension rhs) of
            (Just lhsExt, Just rhsExt) -> ExtRow baseRow <$> supertype lhsExt rhsExt
            _ -> pure $ NoExtRow baseRow

-- | @subtype a b@ checks whether @a@ is a subtype of @b@
subtype :: InfEffs es => Type -> Type -> Eff es ()
subtype = \cases
    lhs rhs | lhs == rhs -> pass -- this case is a bit redundant, since we have to do the same after taking a mono layer anyway
    lhs (T.UniVar uni) -> solveOr lhs (subtype lhs) uni
    (T.UniVar uni) rhs -> solveOr rhs (`subtype` rhs) uni
    lhsTy rhsTy -> join $ match <$> mono In lhsTy <*> mono Out rhsTy
  where
    match = \cases
        lhs rhs | lhs == rhs -> pass -- simple cases, i.e. two type constructors, two univars or two exvars
        -- we *might* have to check for univars once again after applying `mono`
        -- lhs (MUniVar uni) -> solveOr (unMono lhs) (subtype $ unMono lhs) uni
        -- (MUniVar uni) rhs -> solveOr (unMono rhs) (`subtype` unMono rhs) uni
        (MName lhs) (MName rhs) ->
            unlessM (elem (lhs, rhs) <$> builtin (.subtypeRelations)) $
                typeError (pretty lhs <+> "is not a subtype of" <+> pretty rhs)
        (MFn inl outl) (MFn inr outr) -> do
            subtype inr inl
            subtype outl outr
        (MApp lhs rhs) (MApp lhs' rhs') -> do
            -- note that we assume the same variance for all type parameters
            -- some kind of kind system is needed to track variance and prevent stuff like `Maybe a b`
            -- higher-kinded types are also problematic when it comes to variance, i.e.
            -- is `f a` a subtype of `f b` when a is `a` subtype of `b` or the other way around?
            --
            -- QuickLook just assumes that all constructors are invariant and -> is a special case
            subtype lhs lhs'
            subtype rhs rhs'
        (MVariant lhs) (MVariant rhs) -> rowCase Variant lhs rhs
        (MRecord lhs) (MRecord rhs) -> rowCase Record lhs rhs
        lhs rhs -> typeError $ pretty lhs <+> "is not a subtype of" <+> pretty rhs

    rowCase whatToMatch lhsRow rhsRow = do
        let con = conOf whatToMatch
        for_ (IsList.toList lhsRow.row) \(name, lhsTy) ->
            deepLookup whatToMatch name (con rhsRow) >>= \case
                Nothing ->
                    typeError $
                        pretty (con lhsRow) <+> "is not a subtype of" <+> pretty (con rhsRow)
                            <> ": right hand side does not contain" <+> pretty name
                Just rhsTy -> subtype lhsTy rhsTy
        -- if the lhs has an extension, it should be compatible with rhs without the already matched fields
        for_ (Row.extension lhsRow) \ext -> subtype ext . con =<< diff whatToMatch rhsRow lhsRow.row

    -- turns out it's different enough from `withUniVar`
    solveOr :: InfEffs es => Type -> (Type -> Eff es ()) -> UniVar -> Eff es ()
    solveOr solveWith whenSolved uni = lookupUniVar uni >>= either (const $ solveUniVar uni solveWith) whenSolved

check :: InfEffs es => Expr -> Type -> Eff es ()
check e type_ = do
    builtins <- ask @(Builtins Name)
    mono Out type_ >>= match builtins e
  where
    -- most of the cases don't need monomorphisation here
    -- it doesn't make a difference most of the time, since `subtype` monomorphises
    -- its arguments anyway
    --
    -- however, if, say, a lambda argument gets inferred to a univar, that univar would unify
    -- with a monomorphised type rather than a polytype
    --
    -- one option is to make `unMono` behave like univarsToForall / univarsToExists
    match builtins = \cases
        -- the cases for E.Name and E.Constructor are redundant, since
        -- `infer` just looks up their types anyway
        (E.Lambda arg body) (MFn from to) -> scoped do
            -- `checkPattern` updates signatures of all mentioned variables
            checkPattern arg from
            check body to
        (E.Annotation expr ty') ty -> do
            subtype ty' $ unMono ty
            check expr ty'
        (E.If cond true false) ty -> do
            bool <- builtin (.bool)
            check cond $ T.Name bool
            check true $ unMono ty
            check false $ unMono ty
        (E.Case arg matches) ty -> do
            argTy <- infer arg
            for_ matches \(pat, body) -> do
                checkPattern pat argTy
                check body $ unMono ty
        (E.List items) (MApp (T.Name name) itemTy)
            | name == builtins.list -> for_ items (`check` itemTy)
        (E.Record row) ty -> do
            for_ (IsList.toList row) \(name, expr) ->
                deepLookup Record name (unMono ty) >>= \case
                    Nothing -> typeError $ pretty ty <+> "does not contain field" <+> pretty name
                    Just fieldTy -> check expr fieldTy
        expr (MUniVar uni) -> lookupUniVar uni >>= \case
            Right ty -> check expr ty
            Left _ -> solveUniVar uni =<< infer expr

        expr ty -> do
            ty' <- infer expr
            subtype ty' $ unMono ty

checkPattern :: InfEffs es => Pattern' -> Type -> Eff es ()
checkPattern = \cases
    (P.Var name) ty -> updateSig name ty
    -- it's not clear whether value constructors need a separate rule
    (P.Record patRow) ty -> do
        for_ (IsList.toList patRow) \(name, pat) ->
            deepLookup Record name ty >>= \case
                Nothing -> typeError $ pretty ty <+> "does not contain field" <+> pretty name
                Just fieldTy -> checkPattern pat fieldTy
    pat ty -> do
        ty' <- inferPattern pat
        subtype ty' ty

infer :: InfEffs es => Expr -> Eff es Type
infer = \case
    E.Name name -> lookupSig name
    E.Constructor name -> lookupSig name
    E.Variant name -> {-forallScope-} do
        var <- freshUniVar
        rowVar <- freshUniVar
        -- #a -> [Name #a | #r]
        pure $ T.Function var (T.Variant $ ExtRow (fromList [(name, var)]) rowVar)
    E.Application f x -> do
        fTy <- infer f
        inferApp fTy x
    E.Lambda arg body -> {-forallScope-} do
        argTy <- inferPattern arg
        T.Function argTy <$> infer body
    E.Let binding body -> do
        void $ inferBinding binding
        infer body
    E.Annotation expr ty -> ty <$ check expr ty
    E.If cond true false -> do
        bool <- builtin (.bool)
        check cond $ T.Name bool
        trueTy <- infer true
        falseTy <- infer false
        supertype trueTy falseTy
    E.Case arg matches -> do
        argTy <- infer arg
        bodyTypes <- for matches \(pat, body) -> do
            -- overspecification *might* be a problem here if argTy gets inferred to a univar
            -- and the first pattern has a polymorphic type, like `Nothing : forall a. Maybe a`
            -- there's a test for this, and it passes. Weird.
            checkPattern pat argTy
            infer body
        firstTy <- freshUniVar
        foldM supertype firstTy bodyTypes
    E.Match [] -> typeError "empty match expression"
    E.Match (m : ms) -> {-forallScope-} do
        (patTypes, bodyTypes) <-
            NE.unzip <$> for (m :| ms) \(pats, body) -> do
                patTypes <- traverse inferPattern pats
                bodyTy <- infer body
                pure (patTypes, bodyTy)
        unless (all ((== length (NE.head patTypes)) . length) patTypes) $
            typeError "different amount of arguments in a match statement"
        finalPatTypes <- foldlM1 (zipWithM supertype) patTypes
        resultType <- foldlM1 supertype bodyTypes
        pure $ foldr T.Function resultType finalPatTypes
    E.List items -> do
        itemTy <- freshUniVar
        list <- builtin (.list)
        T.Application (T.Name list) <$> (foldM supertype itemTy =<< traverse infer items)
    E.Record row -> T.Record . NoExtRow <$> traverse infer row
    E.RecordLens fields -> do
        recordParts <- for fields \field -> do
            rowVar <- freshUniVar
            pure \nested -> T.Record $ ExtRow (one (field, nested)) rowVar
        let mkNestedRecord = foldr1 (.) recordParts
        a <- freshUniVar
        b <- freshUniVar
        lens <- builtin (.lens)
        pure $
            T.Name lens
                `T.Application` mkNestedRecord a
                `T.Application` mkNestedRecord b
                `T.Application` a
                `T.Application` b
    E.IntLiteral num
        | num >= 0 -> T.Name <$> builtin (.nat)
        | otherwise -> T.Name <$> builtin (.int)
    E.TextLiteral _ -> T.Name <$> builtin (.text)
    E.CharLiteral _ -> T.Name <$> builtin (.char)

-- infers the type of a binding and declares it
-- returns the type if it's a function or a single variable binding
inferBinding :: InfEffs es => Binding Name -> Eff es (Maybe (Name, Type))
inferBinding = \case
    E.ValueBinding pat body -> do
        bodyTy <- infer body
        checkPattern pat bodyTy
        case pat of
            P.Var name -> Just . (name, ) <$> lookupSig name
            _ -> pure Nothing
    E.FunctionBinding name args body -> do
        argTypes <- traverse inferPattern args
        bodyTy <- infer body
        let ty = foldr T.Function bodyTy argTypes
        updateSig name ty
        pure $ Just (name, ty)

inferPattern :: InfEffs es => Pattern' -> Eff es Type
inferPattern = \case
    P.Var name -> do
        uni <- freshUniVar
        updateSig name uni
        pure uni
    P.Annotation pat ty -> ty <$ checkPattern pat ty
    p@(P.Constructor name args) -> do
        (resultType, argTypes) <- conArgTypes name
        unless (length argTypes == length args) $ typeError $ "incorrect arg count in pattern" <+> pretty p
        zipWithM_ checkPattern args argTypes
        pure resultType
    P.List pats -> do
        result <- freshUniVar
        list <- builtin (.list)
        T.Application (T.Name list) <$> (foldM supertype result =<< traverse inferPattern pats)
    P.Variant name arg -> {-forallScope-} do
        argTy <- inferPattern arg
        T.Variant . ExtRow (fromList [(name, argTy)]) <$> freshUniVar
    P.Record row -> do
        typeRow <- traverse inferPattern row
        T.Record . ExtRow typeRow <$> freshUniVar
    P.IntLiteral _ -> T.Name <$> builtin (.int)
    P.TextLiteral _ -> T.Name <$> builtin (.text)
    P.CharLiteral _ -> T.Name <$> builtin (.char)
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
            MUniVar uni -> typeError $ "unexpected univar" <+> pretty uni <+> "in a constructor type"
            -- this kind of repetition is necessary to retain missing pattern warnings
            MName name -> pure (T.Name name, [])
            MApp lhs rhs -> pure (T.Application lhs rhs, [])
            MVariant row -> pure (T.Variant row, [])
            MRecord row -> pure (T.Record row, [])
            MSkolem skolem -> pure (T.Skolem skolem, [])

inferApp :: InfEffs es => Type -> Expr -> Eff es Type
inferApp fTy arg =
    mono In fTy >>= \case
        MUniVar v -> do
            from <- infer arg
            to <- freshUniVar
            lookupUniVar v >>= \case
                Left _ -> do
                    solveUniVar v $ T.Function from to
                    pure to
                Right newTy -> inferApp newTy arg
        MFn from to -> to <$ check arg from
        _ -> typeError $ pretty fTy <+> "is not a function type"
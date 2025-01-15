{-# LANGUAGE RecordWildCards #-}

module DependencyResolution where

import Common
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HashSet
import Diagnostic (Diagnose, fatal, nonFatal)
import Effectful.State.Static.Local
import Effectful.Writer.Static.Local (Writer, runWriter)
import Error.Diagnose (Marker (..), Report (..))
import LangPrelude
import NameGen (freshId, runNameGen)
import Poset (Poset)
import Poset qualified
import Prettyprinter (comma, hsep, punctuate)
import Syntax
import Syntax.Declaration qualified as D
import Syntax.Expression qualified as E
import Syntax.Pattern qualified as P

-- once we've done name resolution, all sorts of useful information may be collected into tables
-- this pass gets rid of the old [Declaration] shape of the AST and transforms it into something more structured

newtype DeclId = DeclId Id deriving (Eq, Hashable)

data Output = Output
    { fixityMap :: FixityMap
    -- ^ operator fixities extracted from Infix declarations
    , operatorPriorities :: Poset Op
    -- ^ operator priorities extracted from Infix declarations and converted to a Poset
    , orderedDeclarations :: [[Decl]]
    -- ^ mutually recursive groups of declarations in processing order
    , declarations :: HashMap DeclId Decl -- since a declaration may yield multiple names, direct name-to-declaration mapping is a no go
    -- given the many-to-one nature of declarations, we need some way to relate them to names
    , nameOrigins :: NameOrigins
    , signatures :: Signatures
    }

type Decl = Declaration 'DependencyRes
type Op = Maybe Name
type FixityMap = HashMap Op Fixity
type DeclSet = Poset DeclId
type NameOrigins = HashMap Name DeclId
type Declarations = HashMap DeclId Decl
type Signatures = HashMap Name (Type' 'DependencyRes)

resolveDependencies :: forall es. Diagnose :> es => [Declaration 'NameRes] -> Eff es Output
resolveDependencies decls = do
    (((((signatures, declarations), nameOrigins), fixityMap), operatorPriorities), declDeps) <-
        runNameGen
            . runState @DeclSet Poset.empty
            . runState @(Poset Op) Poset.empty
            . runState @FixityMap HashMap.empty
            . runState @NameOrigins HashMap.empty
            . runState @Declarations HashMap.empty
            . execState @Signatures HashMap.empty
            $ traverse_ go decls
    let danglingSigs = HashMap.difference signatures $ HashMap.compose declarations nameOrigins
    for_ danglingSigs danglingSigError

    let orderedDeclarations = (map . mapMaybe) (`HashMap.lookup` declarations) $ Poset.ordered declDeps

    pure Output{..}
  where
    -- go :: Declaration 'NameRes -> Eff es ()
    go = \case
        D.Fixity loc fixity op rels -> do
            modify @FixityMap $ HashMap.insert (Just op) fixity
            modifyM @(Poset Op) $ updatePrecedence loc op rels
        D.Value loc binding locals -> do
            -- I'm not sure how to handle locals here, since they may contain mutual recursion
            -- and all of the same complications
            -- seems like we have to run dependency resolution on these bindings locally
            let (binding', dependencies) = collectBindingDependencies binding
            declId <- addDecl (D.Value loc (cast binding) _ProcessedLocals)
            -- traverse the binding body and add a dependency between declarations
            linkNamesToDecl declId $ collectNamesInBinding binding
        D.Type loc name vars constrs -> do
            declId <- addDecl (D.Type loc name (map cast vars) $ map castCon constrs)
            linkNamesToDecl declId $ name : map (.name) constrs
        -- traverse all constructor arguments and add dependencies
        -- these dependencies are only needed for kind checking
        D.GADT{} -> _todo
        D.Signature _ name ty -> do
            modify @Signatures $ HashMap.insert name $ cast ty

    -- addDecl :: Declaration 'DependencyRes -> Eff es DeclId
    addDecl decl = do
        declId <- DeclId <$> freshId
        modify @Declarations $ HashMap.insert declId decl
        pure declId
    -- linkNamesToDecl :: DeclId -> [Name] -> Eff es ()
    linkNamesToDecl declId names =
        modify @NameOrigins \origs -> foldl' (\acc n -> HashMap.insert n declId acc) origs names

    castCon :: Constructor 'NameRes -> Constructor 'DependencyRes
    castCon D.Constructor{loc, name, args} =
        D.Constructor loc (coerce name) $ map (cast uniplateCast) args

collectBindingDependencies :: Binding 'NameRes -> (Binding 'DependencyRes, HashSet Name)
collectBindingDependencies = runPureEff . runState @(HashSet Name) HashSet.empty . go
  where
    go = todo

-- | collects all to-be-declared names in a pattern
collectNames :: Pattern p -> [NameAt p]
collectNames = \case
    P.Var name -> [name]
    P.Wildcard{} -> []
    P.Annotation pat _ -> collectNames pat
    P.Variant _ pat -> collectNames pat
    P.Constructor _ pats -> foldMap collectNames pats
    P.List _ pats -> foldMap collectNames pats
    P.Record _ row -> foldMap collectNames $ toList row
    P.Literal _ -> []

collectNamesInBinding :: Binding p -> [NameAt p]
collectNamesInBinding = \case
    E.FunctionBinding name _ _ -> [name]
    E.ValueBinding pat _ -> collectNames pat

reportCycleWarnings :: (State (Poset Op) :> es, Diagnose :> es) => Loc -> Eff (Writer (Seq (Poset.Cycle Op)) : es) a -> Eff es a
reportCycleWarnings loc action = do
    (x, warnings) <- runWriter action
    poset <- get @(Poset Op)
    for_ warnings \(Poset.Cycle lhsClass rhsClass) -> do
        cycleWarning loc (Poset.items lhsClass poset) (Poset.items rhsClass poset)
    pure x

updatePrecedence :: Diagnose :> es => Loc -> Name -> PriorityRelation 'NameRes -> Poset Op -> Eff es (Poset Op)
updatePrecedence loc op rels poset = execState poset $ Poset.reportError $ reportCycleWarnings loc do
    traverse_ (addRelation GT) rels.above
    traverse_ (addRelation LT) below
    traverse_ (addRelation EQ . Just) rels.equal
  where
    -- all operators implicitly have a lower precedence than function application, unless stated otherwise
    below
        | Nothing `notElem` rels.above = Nothing : map Just rels.below
        | otherwise = map Just rels.below

    addRelation _ op2
        | Just op == op2 = selfRelationError op
    addRelation rel op2 = do
        lhsClass <- state $ Poset.eqClass (Just op)
        rhsClass <- state $ Poset.eqClass op2
        modifyM @(Poset Op) $ Poset.addRelationLenient lhsClass rhsClass rel

-- errors

danglingSigError :: Diagnose :> es => Type' 'DependencyRes -> Eff es ()
danglingSigError ty =
    nonFatal $
        Err
            Nothing
            "Signature lacks an accompanying binding"
            (mkNotes [(getLoc ty, This "this")])
            []

cycleWarning :: Diagnose :> es => Loc -> [Op] -> [Op] -> Eff es ()
cycleWarning loc ops ops2 =
    nonFatal $
        Warn
            Nothing
            ( "priority cycle between" <+> hsep (punctuate comma $ map mbPretty ops) <+> "and" <+> hsep (punctuate comma $ map mbPretty ops2)
            )
            (mkNotes [(loc, This "occured at this declaration")])
            []
  where
    mbPretty Nothing = "function application"
    mbPretty (Just op) = pretty op

selfRelationError :: Diagnose :> es => Name -> Eff es ()
selfRelationError op =
    fatal . one $
        Err
            Nothing
            ("self-reference in fixity declaration" <+> pretty op)
            (mkNotes [(getLoc op, This "is referenced in its own fixity declaration")])
            []

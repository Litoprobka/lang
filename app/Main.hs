{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Relude

import NameResolution
import NameGen (runNameGen)
import Effectful
import Effectful.Error.Static (Error, throwError, runErrorNoCallStack)
import Text.Megaparsec
import Parser (code)
import Data.Sequence qualified as Seq
import Prettyprinter.Render.Text (putDoc)
import Prettyprinter
import TypeChecker (typecheck, TypeError (..))
import Playground (mkDefaults)
import qualified Syntax.Declaration as D
import qualified Data.HashMap.Strict as HashMap
import qualified Syntax.Expression as E
import Interpreter (eval, InterpreterBuiltins (..))
import Infix hiding (parse)
import Common

main :: IO ()
main = do
    args <- getArgs
    (fileName, input) <- case args of
        [] -> ("cli",) <$> getLine
        (path : _) -> (path,) . decodeUtf8 <$> readFileBS path
    input & parse (usingReaderT pos1 code) fileName & \case
        Left err -> putStrLn $ errorBundlePretty err
        Right decls -> do
            mbErr <- runEff $ runNameGen $ runErrorNoCallStack @(Doc ()) do
                traverse_ (liftIO . putDoc . (<> line) . pretty) decls
                (scope, builtins, env) <- mkDefaults
                ((bindings, evalBuiltins, constrs), ScopeErrors errors warnings) <- runNameResolution scope do
                    bindings <- resolveNames decls
                    evalBuiltins <- traverse resolve InterpreterBuiltins{true = "True", cons = "Cons", nil = "Nil"}
                    let constrs = HashMap.empty
                    pure (bindings, evalBuiltins, constrs)

                unless (Seq.null errors) $ putTextLn $ "errors: " <> foldMap show errors
                unless (Seq.null warnings) $ putTextLn $ "warnings: " <> foldMap show warnings

                putTextLn "resolved names:"
                traverse_ (liftIO . putDoc . (<> line) . pretty) bindings

                fixityResolvedBindings <- asError $ resolveFixity testOpMap testGraph bindings

                putTextLn "typechecking:"
                checkedBindings <- asError . first (\(TypeError err) -> err) =<< typecheck env builtins fixityResolvedBindings 
                liftIO . putDoc $ (<> line) $ vsep $ pretty . uncurry (D.Signature Blank) <$> HashMap.toList checkedBindings
                case fixityResolvedBindings of
                    (D.Value _ (E.ValueBinding _ _ body) _) : _ ->
                        liftIO . putDoc $ (<> line) $ pretty $ eval evalBuiltins constrs HashMap.empty body
                    _ -> putTextLn "Not a value"

            case mbErr of
                Left err -> putDoc $ (<> line) $ err
                Right _ -> pass


asError :: Error (Doc ()) :> es => Either (Doc ()) a -> Eff es a
asError = \case
    Left err -> throwError err
    Right val -> pure val
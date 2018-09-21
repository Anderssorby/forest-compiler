{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

import Data.List.NonEmpty (toList)
import Data.Maybe
import Data.Semigroup
import Data.Text
import qualified Data.Text.IO as TIO
import Safe
import System.Environment
import Text.Megaparsec.Error
import Text.RawString.QQ
import System.Exit

import Compiler
import HaskellSyntax
import TypeChecker

usage :: Text
usage = strip
  [r|
usage: forest command path

commands:

  build - typechecks and compiles the given file to Wast
  format - format and print the given file
  check - typechecks the given file
|]

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["build", filename] -> do
      contents <- TIO.readFile filename
      let (text, exitCode) =
            case compile contents of
              Success w -> (w, ExitSuccess)
              ParseErr err -> (reportParseError filename contents err, ExitFailure 1)
              CompileErr errors ->
                ((intercalate "\n\n-----------\n\n" . toList $ printError <$> errors) <>
                "\n", ExitFailure 2)
      TIO.putStrLn text >> exitWith exitCode
    ["format", filename] -> build format filename
    ["check", filename] -> do
      contents <- TIO.readFile filename
      let (text, exitCode) =
            case check contents of
              Success _ -> ("🎉  no errors found 🎉", ExitSuccess)
              ParseErr err -> (reportParseError filename contents err, ExitFailure 1)
              CompileErr errors ->
                ((intercalate "\n\n-----------\n\n" . toList $ printError <$> errors) <>
                "\n", ExitFailure 2)
      TIO.putStrLn text >> exitWith exitCode
    _ -> TIO.putStrLn usage >> exitFailure
  where
    build :: (Text -> Either ParseError' Text) -> String -> IO ()
    build f filename = do
      contents <- TIO.readFile filename
      case f contents of
        Right a -> TIO.putStrLn a
        Left err -> (TIO.putStrLn $ reportParseError filename contents err) >> exitWith (ExitFailure 1)
    printError (CompileError error message) =
      case error of
        ExpressionError expr ->
          "Encountered a type error in an expression:\n\n" <>
          indent2 (printExpression expr) <>
          "\n\n" <>
          message
        DeclarationError decl ->
          "Encountered a type error in a declaration:\n\n" <>
          indent2 (printDeclaration decl) <>
          "\n\n" <>
          message

reportParseError :: String -> Text -> ParseError' -> Text
reportParseError filename contents err =
  "Syntax error in " <> pack filename <> "\n" <>
  pack (parseErrorPretty' (unpack contents) err)

{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE FlexibleInstances #-}

module TypeCheckerSpec
  ( typeCheckerSpecs
  ) where

import Data.Either
import Data.List.NonEmpty (NonEmpty(..))
import System.Exit
import System.IO.Temp
import System.Process
import Test.Hspec
import Text.RawString.QQ

import HaskellSyntax
import Language
import TypeChecker

valid :: String
valid =
  [r|
add :: Int -> Int -> Int
add a b = a + b

main :: Int
main =
  add 1 1
|]

invalid :: String
invalid =
  [r|
add :: Int -> Int -> Int
add a b = a + b

main :: Int
main =
  add 1 "test"
|]

local :: String
local =
  [r|
add :: Int -> Int -> Int
add a b = a + b

addOne :: Int -> Int
addOne n =
  add n 1
|]

wrongReturnType :: String
wrongReturnType =
  [r|
foo :: Int
foo = "test"
|]

badCase :: String
badCase =
  [r|
main :: Int
main =
  case 5 of
    1 -> "Test"
    2 -> 2
|]

goodCase :: String
goodCase =
  [r|
main :: Int
main =
  case 5 of
    1 -> 1
    2 -> 2
    i -> 5
|]

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe either =
  case either of
    Left _ -> Nothing
    Right b -> Just b

validPrograms :: [String]
validPrograms = [valid, local]

typeCheckerSpecs :: SpecWith ()
typeCheckerSpecs =
  describe "Type checker" $ do
    it "checks valid expressions" $
      let moduleResult = parseModule valid
          checkResult =
            case moduleResult of
              Right m -> checkModule m
              Left err ->
                Left
                  (CompileError ("Failed to parse module: " ++ show err) :| [])
       in checkResult `shouldBe` Right ()
    it "checks valid expressions that use locals" $
      let moduleResult = parseModule local
          checkResult =
            case moduleResult of
              Right m -> checkModule m
              Left err ->
                Left
                  (CompileError ("Failed to parse module: " ++ show err) :| [])
       in checkResult `shouldBe` Right ()
    it "checks invalid expressions" $
      let moduleResult = parseModule invalid
          checkResult =
            case moduleResult of
              Right m -> checkModule m
              Left err ->
                Left
                  (CompileError ("Failed to parse module: " ++ show err) :| [])
       in checkResult `shouldBe`
          Left (CompileError "Expected Num, got Str" :| [])
    it "fails if a function has an incorrect return type" $
      let moduleResult = parseModule wrongReturnType
          checkResult =
            case moduleResult of
              Right m -> checkModule m
              Left err ->
                Left
                  (CompileError ("Failed to parse module: " ++ show err) :| [])
       in checkResult `shouldBe`
          Left (CompileError "Expected Num, got Str" :| [])
    it "fails if a case has branches that return different types" $
      let moduleResult = parseModule badCase
          checkResult =
            case moduleResult of
              Right m -> checkModule m
              Left err ->
                Left
                  (CompileError ("Failed to parse module: " ++ show err) :| [])
       in checkResult `shouldBe`
          Left (CompileError "Case statement had multiple return types: Str, Num" :| [])
    it "passes with a valid case" $
      let moduleResult = parseModule goodCase
          checkResult =
            case moduleResult of
              Right m -> checkModule m
              Left err ->
                Left
                  (CompileError ("Failed to parse module: " ++ show err) :| [])
       in checkResult `shouldBe` Right ()

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE FlexibleInstances #-}

import Control.Monad
import qualified Data.List.NonEmpty as NE
import System.Exit
import System.IO.Temp
import System.Process
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Arbitrary

import Compiler
import HaskellSyntax

instance Arbitrary Module where
  arbitrary = genModule
  shrink = genericShrink

instance Arbitrary Expression where
  arbitrary = genExpression
  shrink = genericShrink

instance Arbitrary OperatorExpr where
  arbitrary = genOperator
  shrink = genericShrink

instance Arbitrary Declaration where
  arbitrary = genDeclaration
  shrink = genericShrink

instance Arbitrary Annotation where
  arbitrary = genAnnotation
  shrink = genericShrink

instance Arbitrary Ident where
  arbitrary = genIdent
  shrink (Ident s) = Ident <$> filter permittedWord (shrink s)

permittedWord :: NonEmptyString -> Bool
permittedWord (NonEmptyString s) = NE.toList s `notElem` rws

instance Arbitrary NonEmptyString where
  arbitrary = genString
  shrink (NonEmptyString s) = NonEmptyString <$> shrinkNonEmpty s

instance Arbitrary (NE.NonEmpty Declaration) where
  arbitrary = genNonEmpty genDeclaration
  shrink = shrinkNonEmpty

instance Arbitrary (NE.NonEmpty (Expression, Expression)) where
  arbitrary = genNonEmpty genCaseBranch
  shrink = shrinkNonEmpty

instance Arbitrary (NE.NonEmpty Ident) where
  arbitrary = genNonEmpty genIdent
  shrink = shrinkNonEmpty

genModule :: Gen Module
genModule = Module <$> listOf1 genDeclaration

genNonEmpty :: Gen a -> Gen (NE.NonEmpty a)
genNonEmpty gen = NE.fromList <$> listOf1 gen

shrinkNonEmpty :: Arbitrary a => NE.NonEmpty a -> [NE.NonEmpty a]
shrinkNonEmpty n =
  let list = NE.toList n
      possibilities = shrink list
      nonEmptyPossibilities = filter (not . null) possibilities
   in map NE.fromList nonEmptyPossibilities

genExpression :: Gen Expression
genExpression =
  frequency [(80, genIdentifier), (80, genNumber), (10, genInfix), (1, genLet), (1, genCase)]

genChar :: Gen Char
genChar = elements (['a' .. 'z'] ++ ['A' .. 'Z'])

genIdent :: Gen Ident
genIdent = Ident <$> suchThat genString permittedWord

genString :: Gen NonEmptyString
genString = NonEmptyString . NE.fromList <$> listOf1 genChar

genIdentifier :: Gen Expression
genIdentifier = Identifier <$> genIdent

genNumber :: Gen Expression
genNumber = Number <$> arbitrarySizedNatural

genDeclaration :: Gen Declaration
genDeclaration = do
  name <- genIdent
  annotation <- genMaybe genAnnotation
  args <- listOf genIdent
  expr <- genExpression
  return $ Declaration annotation name args expr

genAnnotation :: Gen Annotation
genAnnotation = do
  name <- genIdent
  types <- genNonEmpty genIdent
  return $ Annotation name types

genMaybe :: Gen a -> Gen (Maybe a)
genMaybe g = oneof [Just <$> g, Nothing <$ g]

genOperator :: Gen OperatorExpr
genOperator = elements [Add, Subtract, Multiply, Divide]

genInfix :: Gen Expression
genInfix = do
  operator <- genOperator
  a <- genNumber
  b <- genExpression
  return $ BetweenParens $ Infix operator a b

genCall :: Gen Expression
genCall = do
  name <- genIdent
  args <- listOf1 genIdentifier
  return $ Call name args

(>*<) :: Gen a -> Gen b -> Gen (a, b)
x >*< y = liftM2 (,) x y

genCase :: Gen Expression
genCase = do
  caseExpr <- genExpression
  cases <- genNonEmpty genCaseBranch
  return $ Case caseExpr cases

genCaseBranch :: Gen (Expression, Expression)
genCaseBranch = oneof [genNumber, genIdentifier] >*< genExpression

genLet :: Gen Expression
genLet = do
  declarations <- genNonEmpty genDeclaration
  expr <- genExpression
  return $ Let declarations expr

propParseAndPrint :: Module -> Bool
propParseAndPrint expr =
  let output = printModule expr
      reparsedExpr = parseModule output
   in case reparsedExpr of
        Right newExpr -> newExpr == expr
        Left _ -> False

main :: IO ()
main =
  hspec $
  describe "Forest haskell syntax" $ do
    it "prints and reparses arbitrary expressions losslessly" $
      property propParseAndPrint
    it "parses a module with multple assignments" $ do
      code <- readFixture "multiple-assignments"
      let parseResult = parseModule code
      let expected =
            Module
              [ Declaration
                  Nothing
                  (ne "double")
                  [ne "a"]
                  (Infix Multiply (Identifier (ne "a")) (Number 2))
              , Declaration
                  Nothing
                  (ne "half")
                  [ne "a"]
                  (Infix Divide (Identifier (ne "a")) (Number 2))
              ]
      parseResult `shouldBe` Right expected
    it "parses an assignment with a case statement" $ do
      code <- readFixture "case-statement"
      let parseResult = parseModule code
      let expected =
            Module
              [ Declaration
                  Nothing
                  (ne "test")
                  [ne "n"]
                  (Case
                     (Identifier (ne "n"))
                     [ (Number 0, Number 1)
                     , (Number 1, Number 1)
                     , ( Identifier (ne "n")
                       , Infix Add (Identifier (ne "n")) (Number 1))
                     ])
              ]
      parseResult `shouldBe` Right expected
    it
      "parses an assignment with a case statement followed by another assignment" $ do
      code <- readFixture "case-statement-and-more"
      let parseResult = parseModule code
      let expected =
            Module
              [ Declaration
                  Nothing
                  (ne "test")
                  [ne "n"]
                  (Case
                     (Identifier (ne "n"))
                     [ (Number 0, Number 1)
                     , (Number 1, Number 1)
                     , (Identifier (ne "n"), Identifier (ne "n"))
                     ])
              , Declaration
                  Nothing
                  (ne "double")
                  [ne "x"]
                  (Infix Multiply (Identifier (ne "x")) (Number 2))
              ]
      parseResult `shouldBe` Right expected
    it "parses let expressions" $ do
      code <- readFixture "let"
      let parseResult = parseModule code
      let expected =
            Module
              [ Declaration
                  Nothing
                  (ne "a")
                  []
                  (Let
                     (NE.fromList
                        [ Declaration Nothing (ne "foo") [] (Number 5)
                        , Declaration Nothing (ne "bar") [] (Number 10)
                        ])
                     (Infix Add (Identifier (ne "foo")) (Identifier (ne "bar"))))
              ]
      parseResult `shouldBe` Right expected

ne :: String -> Ident
ne = Ident . NonEmptyString . NE.fromList

readFixture :: String -> IO String
readFixture name = readFile ("test/fixtures/" ++ name ++ ".tree")

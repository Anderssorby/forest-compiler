{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# OPTIONS -Wall #-}

module HaskellSyntax
  ( printExpression
  , printModule
  , parseModule
  , Expression(..)
  , Module(..)
  , ParseError'
  , OperatorExpr(..)
  , Declaration(..)
  , Annotation(..)
  , NonEmptyString(..)
  , Ident(..)
  , rws
  , s
  , expr
  ) where

import Control.Applicative (empty)
import Control.Monad (void)
import Data.Functor.Identity ()
import Data.List (intercalate)
import qualified Data.List.NonEmpty as NE
import Data.Semigroup
import Data.Text ()
import Data.Void (Void)
import qualified Generics.Deriving as G

import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import Text.Megaparsec.Expr

type Parser = Parsec Void String

type ParseError' = ParseError Char Void

newtype NonEmptyString =
  NonEmptyString (NE.NonEmpty Char)
  deriving (Show, Eq)

idToString :: Ident -> String
idToString (Ident str) = neToString str

neToString :: NonEmptyString -> String
neToString (NonEmptyString se) = NE.toList se

s :: Ident -> String
s = idToString

data OperatorExpr
  = Add
  | Subtract
  | Divide
  | Multiply
  deriving (Show, Eq, G.Generic)

newtype Ident =
  Ident NonEmptyString
  deriving (Show, Eq)

data Expression
  = Identifier Ident
  | Number Int
  | Infix OperatorExpr
          Expression
          Expression
  | Call Ident
         [Expression]
  | Case Expression
         (NE.NonEmpty (Expression, Expression))
  | Let (NE.NonEmpty Declaration)
        Expression
  | BetweenParens Expression
  deriving (Show, Eq, G.Generic)

data Declaration =
  Declaration (Maybe Annotation)
              Ident
              [Ident]
              Expression
  deriving (Show, Eq, G.Generic)

data Annotation =
  Annotation Ident
             (NE.NonEmpty Ident)
  deriving (Show, Eq, G.Generic)

newtype Module =
  Module [Declaration]
  deriving (Show, Eq, G.Generic)

lineComment :: Parser ()
lineComment = L.skipLineComment "#"

scn :: Parser ()
scn = L.space space1 lineComment empty

sc :: Parser ()
sc = L.space (void $ takeWhile1P Nothing f) lineComment empty
  where
    f x = x == ' ' || x == '\t'

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

exprWithoutCall :: Parser Expression
exprWithoutCall = makeExprParser (lexeme termWithoutCall) table <?> "expression"

expr :: Parser Expression
expr = makeExprParser (lexeme term) table <?> "expression"

term :: Parser Expression
term = sc *> (try pCase <|> try pLet <|> parens <|> call <|> number)

termWithoutCall :: Parser Expression
termWithoutCall =
  sc *> (try pCase <|> try pLet <|> parens <|> identifier <|> number)

symbol :: String -> Parser String
symbol = L.symbol sc

parens :: Parser Expression
parens = BetweenParens <$> between (symbol "(" *> scn) (scn <* symbol ")") expr

table :: [[Operator Parser Expression]]
table =
  [ [InfixL (Infix Divide <$ char '/')]
  , [InfixL (Infix Multiply <$ char '*')]
  , [InfixL (Infix Add <$ char '+')]
  , [InfixL (Infix Subtract <$ char '-')]
  ]

number :: Parser Expression
number = Number <$> (sc *> L.decimal)

rws :: [String] -- list of reserved words
rws = ["case", "of", "let"]

pIdent :: Parser Ident
pIdent = (lexeme . try) (p >>= check)
  where
    p = (:) <$> letterChar <*> many alphaNumChar
    check x =
      if x `elem` rws
        then fail $ "keyword " ++ show x ++ " cannot be an identifier"
        else case NE.nonEmpty x of
               Just n -> return $ (Ident . NonEmptyString) n
               Nothing -> fail "identifier must be longer than zero characters"

pCase :: Parser Expression
pCase = L.indentBlock scn p
  where
    p = do
      _ <- symbol "case"
      sc
      caseExpr <- expr
      scn
      _ <- symbol "of"
      return $
        L.IndentSome Nothing (return . Case caseExpr . NE.fromList) caseBranch
    caseBranch = do
      sc
      pattern' <- number <|> identifier
      sc
      _ <- symbol "->"
      scn
      branchExpr <- expr
      return (pattern', branchExpr)

pLet :: Parser Expression
pLet = do
  declarations <- pDeclarations
  _ <- symbol "in"
  scn
  expression <- expr
  return $ Let declarations expression
  where
    pDeclarations = L.indentBlock scn p
    p = do
      _ <- symbol "let"
      return $ L.IndentSome Nothing (return . NE.fromList) declaration

call :: Parser Expression
call = do
  name <- pIdent
  args <- many (try exprWithoutCall)
  return $
    case length args of
      0 -> Identifier name
      _ -> Call name args

identifier :: Parser Expression
identifier = Identifier <$> pIdent

tld :: Parser Declaration
tld = L.nonIndented scn declaration

declaration :: Parser Declaration
declaration = do
  annotation' <- maybeParse annotation
  sc
  name <- pIdent
  args <- many (try (sc *> pIdent))
  sc
  _ <- symbol "="
  scn
  expression <- expr
  scn
  return $ Declaration annotation' name args expression
  where
    annotation = do
      name <- pIdent
      sc
      _ <- symbol "::"
      sc
      firstType <- pIdent
      types <- many pType
      scn
      return $ Annotation name (NE.fromList $ firstType : types)
    pType = do
      _ <- symbol "->"
      sc
      pIdent

maybeParse :: Parser a -> Parser (Maybe a)
maybeParse parser = (Just <$> try parser) <|> Nothing <$ symbol "" -- TODO fix symbol "" hack

parseModule :: String -> Either ParseError' Module
parseModule = parse pModule ""
  where
    pModule = Module <$> many tld <* eof

printModule :: Module -> String
printModule (Module declarations) =
  intercalate "\n\n" $ map printDeclaration declarations

printDeclaration :: Declaration -> String
printDeclaration (Declaration annotation name args expr') =
  annotationAsString <> unwords ([s name] <> (s <$> args) <> ["="]) ++
  "\n" ++ indent2 (printExpression expr')
  where
    annotationAsString = maybe "" printAnnotation annotation

printAnnotation :: Annotation -> String
printAnnotation (Annotation name types) =
  s name <> " :: " <> intercalate " -> " (NE.toList $ s <$> types) <> "\n"

printExpression :: Expression -> String
printExpression expression =
  case expression of
    Number n -> show n
    Infix op expr' expr'' ->
      unwords
        [printExpression expr', operatorToString op, printSecondInfix expr'']
    Identifier name -> s name
    Call name args -> s name ++ " " ++ unwords (printExpression <$> args)
    Case caseExpr patterns ->
      if isComplex caseExpr
        then "case\n" ++
             indent2 (printExpression caseExpr) ++
             "\nof\n" ++ indent2 (printPatterns patterns)
        else "case " ++
             printExpression caseExpr ++
             " of\n" ++ indent2 (printPatterns patterns)
    BetweenParens expr' ->
      if isComplex expr'
        then "(\n" ++ indent2 (printExpression expr') ++ "\n)"
        else "(" ++ printExpression expr' ++ ")"
    Let declarations expr' -> printLet declarations expr'
  where
    printPatterns patterns = unlines $ NE.toList $ printPattern <$> patterns
    printPattern (patternExpr, resultExpr) =
      printExpression patternExpr ++ " -> " ++ printSecondInfix resultExpr
    printLet declarations expr' =
      intercalate "\n" $
      concat
        [ ["let"]
        , indent2 . printDeclaration <$> NE.toList declarations
        , ["in"]
        , [indent2 $ printExpression expr']
        ]
    printSecondInfix expr' =
      if isComplex expr'
        then "\n" ++ indent2 (printExpression expr')
        else printExpression expr'

isComplex :: Expression -> Bool
isComplex expr' =
  case expr' of
    Let {} -> True
    Case {} -> True
    Infix _ a b -> isComplex a || isComplex b
    _ -> False

indent :: Int -> String -> String
indent level str =
  intercalate "\n" $ map (\line -> replicate level ' ' ++ line) (lines str)

indent2 :: String -> String
indent2 = indent 2

operatorToString :: OperatorExpr -> String
operatorToString op =
  case op of
    Add -> "+"
    Subtract -> "-"
    Multiply -> "*"
    Divide -> "/"

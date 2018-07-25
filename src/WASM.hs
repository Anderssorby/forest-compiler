{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE QuasiQuotes #-}

module Wasm
  ( Expression(..)
  , Module(..)
  , printWasm
  , forestModuleToWasm
  ) where

import qualified Language as F

import Control.Arrow ((***))
import Data.Char
import Data.List (intercalate)
import qualified Data.List.NonEmpty as NE
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Maybe
import Data.Semigroup ((<>))
import Data.Text (Text)
import qualified Generics.Deriving as G
import Text.RawString.QQ

import TypeChecker
import qualified TypeChecker as T

type BytesAllocated = Int

data Module =
  Module [TopLevel]
         BytesAllocated

data Declaration =
  Declaration F.Ident
              [F.Ident]
              Expression
  deriving (Show, Eq, G.Generic)

data TopLevel
  = Func Declaration
  | Data Int
         String

data Expression
  = Const Int
  | GetLocal F.Ident
  | SetLocal F.Ident
             Expression
  | Call F.Ident
         [Expression]
  | NamedCall F.Ident
              [Expression]
  | If Expression
       Expression
       (Maybe Expression)
  | Sequence (NE.NonEmpty Expression)
  deriving (Show, Eq)

-- TODO - malloc could probably be better
prelude :: BytesAllocated -> String
prelude bytesAllocated =
  let freeBlock =
        ("(global $freeblock (mut i32) (i32.const " ++
         show bytesAllocated ++ "))\n\n")
   in freeBlock ++
      [r|

(export "malloc" (func $malloc))
(func $malloc (param $size i32) (result i32)
  (local $address i32)
  (set_local $address (get_global $freeblock))
  (set_global $freeblock (i32.add (get_local $address) (get_local $size)))
  (return (get_local $address))
)

(func $string_copy (param $from i32) (param $to i32) (result i32)
  (local $index i32)
  (local $size i32)

  (set_local $index (i32.const 1))
  (set_local $size (i32.load8_u (get_local $from)))

  (loop $copy
    (i32.store8
      (i32.add (get_local $to) (get_local $index))
      (i32.load8_u (i32.add (get_local $from) (get_local $index)))
    )
    (set_local $index (i32.add (get_local $index) (i32.const 1)))
    (br_if $copy (i32.lt_s (get_local $index) (get_local $size)))
  )

  (return (get_local $size))
)

(func $string_add (param $a i32) (param $b i32) (result i32)
  (local $sum i32)
  (local $aSize i32)
  (local $newStr i32)
  (return
    (set_local $aSize (i32.load8_u (get_local $a)))
    (set_local $sum
      (i32.sub
        (i32.add
          (get_local $aSize)
          (i32.load8_u (get_local $b))
        )
        (i32.const 1)
      )
    )
    (set_local $newStr (call $malloc (i32.add (get_local $sum) (i32.const 1))))
    (i32.store8 (get_local $newStr) (get_local $sum))
    (call $string_copy (get_local $a) (get_local $newStr))
    (call $string_copy (get_local $b) (i32.sub (i32.add (get_local $newStr) (get_local $aSize)) (i32.const 1)))
    (get_local $newStr)
  )
)
|]

indent :: Int -> String -> String
indent level str =
  intercalate "\n" $ map (\line -> replicate level ' ' ++ line) (lines str)

indent2 :: String -> String
indent2 = indent 2

forestModuleToWasm :: TypedModule -> Module
forestModuleToWasm (TypedModule topLevel) =
  foldl compileDeclaration initModule topLevel
  where
    initModule = Module [] 0

addTopLevel :: Module -> [TopLevel] -> Module
addTopLevel (Module topLevel bytes) newTopLevel =
  Module (topLevel ++ newTopLevel) bytes

allocateBytes :: Module -> Int -> Module
allocateBytes (Module topLevel bytes) extraBytes =
  Module topLevel (bytes + extraBytes)

compileDeclaration :: Module -> TypedDeclaration -> Module
compileDeclaration m (TypedDeclaration name args fexpr) =
  let (m', expr') = compileExpression m fexpr
      func = Func $ Declaration name (fst <$> args) expr'
   in addTopLevel m' [func]

compileInlineDeclaration ::
     Module -> TypedDeclaration -> (Maybe Expression, Module)
compileInlineDeclaration m (TypedDeclaration name args fexpr) =
  let (m', expr') = compileExpression m fexpr
   in case args of
        [] -> (Just $ SetLocal name expr', m')
        _ ->
          ( Nothing
          , addTopLevel m' [Func $ Declaration name (fst <$> args) expr'])

compileExpressions ::
     Module -> NonEmpty TypedExpression -> (Module, [Expression])
compileExpressions m = foldl compile (m, [])
  where
    compile (m, xs) te =
      let (m', e) = compileExpression m te
       in (m', e : xs)

compileExpression :: Module -> TypedExpression -> (Module, Expression)
compileExpression m fexpr =
  case fexpr of
    T.Identifier _ i -> (m, GetLocal i)
    T.Number n -> (m, Const n)
    T.BetweenParens fexpr -> compileExpression m fexpr
    T.Infix _ operator a b ->
      let (m', aExpr) = compileExpression m a
          (m'', bExpr) = compileExpression m' b
          name = (F.Ident $ F.NonEmptyString $ NE.fromList "string_add")
       in case operator of
            F.StringAdd -> (m'', NamedCall name [aExpr, bExpr])
            _ -> (m'', Call (funcForOperator operator) [aExpr, bExpr])
    T.Apply _ left right ->
      case left of
        T.Apply _ (T.Identifier _ name) r' ->
          let (m', exprs) = compileExpressions m [right, r']
           in (m', Sequence $ NE.fromList (exprs ++ [NamedCall name []]))
        T.Identifier _ name ->
          let (m', r) = compileExpression m right
           in (m', NamedCall name [r])
        _ -> error $ "do not know what to do with " ++ show left
      -- say that left refers to a function declaration
      -- and that right refers to a number
      -- we want to generate a namedcall
    T.Case _ caseFexpr patterns ->
      let (m', caseExpr) = compileExpression m caseFexpr
          (m'', patternExprs) = patternsToWasm m' patterns
       in (m'', constructCase caseExpr patternExprs)
    T.Let declarations fexpr ->
      let compileDeclaration' (m', declarations) declaration =
            let (mExpr, m'') = compileInlineDeclaration m' declaration
             in case mExpr of
                  Just expr -> (m'', declarations ++ [expr])
                  Nothing -> (m'', declarations)
          (m', declarationExpressions) =
            foldl compileDeclaration' (m, []) declarations
          (m'', expr') = compileExpression m' fexpr
       in (m'', Sequence $ NE.fromList (declarationExpressions <> [expr']))
    T.String' str ->
      let (Module _ address) = m
          m' = addTopLevel m [Data address str]
          m'' = allocateBytes m' (length str + 1)
       in (m'', Const address)
  where
    constructCase ::
         Expression -> NE.NonEmpty (Expression, Expression) -> Expression
    constructCase caseExpr patterns =
      case patterns of
        [x] -> If (Call eq32 [caseExpr, fst x]) (snd x) Nothing
        (x :| xs) ->
          If
            (Call eq32 [caseExpr, fst x])
            (snd x)
            (Just (constructCase caseExpr (NE.fromList xs)))
    patternsToWasm m patterns =
      let compilePattern (m', exprs) (a, b) =
            let (m'', aExpr) = compileExpression m' a
                (m''', bExpr) = compileExpression m'' b
             in (m''', exprs ++ [(aExpr, bExpr)])
          (m', exprs) = foldl compilePattern (m, []) patterns
       in (m', NE.fromList exprs)

eq32 :: F.Ident
eq32 = F.Ident . F.NonEmptyString $ NE.fromList "i32.eq"

funcForOperator :: F.OperatorExpr -> F.Ident
funcForOperator operator =
  F.Ident . F.NonEmptyString $
  NE.fromList $
  case operator of
    F.Add -> "i32.add"
    F.Subtract -> "i32.sub"
    F.Multiply -> "i32.mul"
    F.Divide -> "i32.div_s"
    F.StringAdd -> "string_add"

printWasm :: Module -> String
printWasm (Module expressions bytesAllocated) =
  "(module\n" ++
  indent2 (prelude bytesAllocated) ++
  "\n\n" ++
  indent2 (printMemory bytesAllocated) ++
  "\n" ++
  indent2 (intercalate "\n" $ printWasmTopLevel <$> expressions) ++ "\n)"

printMemory :: BytesAllocated -> String
printMemory bytes =
  case bytes of
    0 -> printMemory 1 -- TODO this is silly, we should omit the prelude instead
    _ ->
      "(memory $memory " ++
      show pages ++ ")\n(export \"memory\" (memory $memory))\n\n"
  where
    pageSize = 2 ** 16
    pages = ceiling $ fromIntegral bytes / pageSize

printWasmTopLevel :: TopLevel -> String
printWasmTopLevel topLevel =
  case topLevel of
    Func (Declaration name args body) ->
      unlines
        [ "(export \"" ++ F.s name ++ "\" (func $" ++ F.s name ++ "))"
        , printDeclaration (Declaration name args body)
        ]
    Data offset str ->
      "(data (i32.const " ++
      show offset ++ ") \"" ++ escape (length str + 1) ++ str ++ "\")"
  where
    escape n =
      case n of
        0 -> "\\" ++ [chr 0]
        34 -> "\\\""
        _ -> [chr n]

printWasmExpr :: Expression -> String
printWasmExpr expr =
  case expr of
    Sequence exprs -> intercalate "\n" $ NE.toList (printWasmExpr <$> exprs)
    Const n -> "(i32.const " ++ show n ++ ")"
    GetLocal name -> "(get_local $" ++ F.s name ++ ")"
    SetLocal name expr' ->
      "(set_local $" ++ F.s name ++ " " ++ printWasmExpr expr' ++ ")"
    Call name args ->
      "(" ++
      F.s name ++ "\n" ++ indent2 (unlines (printWasmExpr <$> args)) ++ "\n)"
    NamedCall name args ->
      "(call $" ++
      F.s name ++ "\n" ++ indent2 (unlines (printWasmExpr <$> args)) ++ "\n)"
    If conditional a b ->
      unlines
        ([ "(if (result i32)"
         , indent2 $ printWasmExpr conditional
         , indent2 $ printWasmExpr a
         ] <>
         [indent2 $ maybe "(i32.const 0)" printWasmExpr b, ")"])

printDeclaration :: Declaration -> String
printDeclaration (Declaration name args body) =
  intercalate
    "\n"
    [ "(func $" ++
      F.s name ++
      unwords (map (\x -> " (param $" ++ x ++ " i32)") (F.s <$> args)) ++
      " (result i32) " ++ unwords (printLocal <$> locals body)
    , indent2 $ unlines ["(return", indent2 $ printWasmExpr body, ")"]
    , ")"
    ]
  where
    locals :: Expression -> [String]
    locals expr' =
      case expr' of
        SetLocal name _ -> [F.s name]
        Sequence exprs -> concatMap locals $ NE.toList exprs
        _ -> []
    -- TODO - there are probably other important cases we should handle here

printLocal :: String -> String
printLocal name = "(local $" ++ name ++ " i32)"

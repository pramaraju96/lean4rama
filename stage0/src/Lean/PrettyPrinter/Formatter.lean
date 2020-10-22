#lang lean4
/-
Copyright (c) 2020 Sebastian Ullrich. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Sebastian Ullrich
-/

/-!
The formatter turns a `Syntax` tree into a `Format` object, inserting both mandatory whitespace (to separate adjacent
tokens) as well as "pretty" optional whitespace.

The basic approach works much like the parenthesizer: A right-to-left traversal over the syntax tree, driven by
parser-specific handlers registered via attributes. The traversal is right-to-left so that when emitting a token, we
already know the text following it and can decide whether or not whitespace between the two is necessary.
-/

import Lean.CoreM
import Lean.Parser.Extension
import Lean.KeyedDeclsAttribute
import Lean.ParserCompiler.Attribute
import Lean.PrettyPrinter.Backtrack

namespace Lean
namespace PrettyPrinter
namespace Formatter

structure Context :=
  (options : Options)
  (table   : Parser.TokenTable)

structure State :=
  (stxTrav  : Syntax.Traverser)
  -- Textual content of `stack` up to the first whitespace (not enclosed in an escaped ident). We assume that the textual
  -- content of `stack` is modified only by `pushText` and `pushLine`, so `leadWord` is adjusted there accordingly.
  (leadWord : String := "")
  -- Stack of generated Format objects, analogous to the Syntax stack in the parser.
  -- Note, however, that the stack is reversed because of the right-to-left traversal.
  (stack    : Array Format := #[])

end Formatter

abbrev FormatterM := ReaderT Formatter.Context $ StateRefT Formatter.State $ CoreM

@[inline] def FormatterM.orelse {α} (p₁ p₂ : FormatterM α) : FormatterM α := do
  let s ← get
  catchInternalId backtrackExceptionId
    p₁
    (fun _ => do set s; p₂)

instance Formatter.orelse {α} : HasOrelse (FormatterM α) := ⟨FormatterM.orelse⟩

abbrev Formatter := FormatterM Unit

unsafe def mkFormatterAttribute : IO (KeyedDeclsAttribute Formatter) :=
  KeyedDeclsAttribute.init {
    builtinName := `builtinFormatter,
    name := `formatter,
    descr := "Register a formatter for a parser.

  [formatter k] registers a declaration of type `Lean.PrettyPrinter.Formatter` for the `SyntaxNodeKind` `k`.",
    valueTypeName := `Lean.PrettyPrinter.Formatter,
    evalKey := fun builtin args => do
      let env ← getEnv
      match attrParamSyntaxToIdentifier args with
      | some id =>
        -- `isValidSyntaxNodeKind` is updated only in the next stage for new `[builtin*Parser]`s, but we try to
        -- synthesize a formatter for it immediately, so we just check for a declaration in this case
        if (builtin && (env.find? id).isSome) || Parser.isValidSyntaxNodeKind env id then pure id
        else throwError ("invalid [formatter] argument, unknown syntax kind '" ++ toString id ++ "'")
      | none    => throwError "invalid [formatter] argument, expected identifier"
  } `Lean.PrettyPrinter.formatterAttribute
@[builtinInit mkFormatterAttribute] constant formatterAttribute : KeyedDeclsAttribute Formatter := arbitrary _

unsafe def mkCombinatorFormatterAttribute : IO ParserCompiler.CombinatorAttribute :=
  ParserCompiler.registerCombinatorAttribute
    `combinatorFormatter
    "Register a formatter for a parser combinator.

  [combinatorFormatter c] registers a declaration of type `Lean.PrettyPrinter.Formatter` for the `Parser` declaration `c`.
  Note that, unlike with [formatter], this is not a node kind since combinators usually do not introduce their own node kinds.
  The tagged declaration may optionally accept parameters corresponding to (a prefix of) those of `c`, where `Parser` is replaced
  with `Formatter` in the parameter types."
@[builtinInit mkCombinatorFormatterAttribute] constant combinatorFormatterAttribute : ParserCompiler.CombinatorAttribute := arbitrary _

namespace Formatter

open Lean.Core
open Lean.Parser

def throwBacktrack {α} : FormatterM α :=
throw $ Exception.internal backtrackExceptionId

instance FormatterM.monadTraverser : Syntax.MonadTraverser FormatterM := ⟨{
  get       := State.stxTrav <$> get,
  set       := fun t => modify (fun st => { st with stxTrav := t }),
  modifyGet := fun f => modifyGet (fun st => let (a, t) := f st.stxTrav; (a, { st with stxTrav := t }))
}⟩

open Syntax.MonadTraverser

def getStack : FormatterM (Array Format) := do
  let st ← get
  pure st.stack

def getStackSize : FormatterM Nat := do
  let stack ← getStack;
  pure stack.size

def setStack (stack : Array Format) : FormatterM Unit :=
  modify fun st => { st with stack := stack }

def push (f : Format) : FormatterM Unit :=
  modify fun st => { st with stack := st.stack.push f }

def pushLine : FormatterM Unit := do
  push Format.line;
  modify fun st => { st with leadWord := "" }

/-- Execute `x` at the right-most child of the current node, if any, then advance to the left. -/
def visitArgs (x : FormatterM Unit) : FormatterM Unit := do
  let stx ← getCur
  if stx.getArgs.size > 0 then
    goDown (stx.getArgs.size - 1) *> x <* goUp
  goLeft

/-- Execute `x`, pass array of generated Format objects to `fn`, and push result. -/
def fold (fn : Array Format → Format) (x : FormatterM Unit) : FormatterM Unit := do
  let sp ← getStackSize
  x
  let stack ← getStack
  let f := fn $ stack.extract sp stack.size
  setStack $ (stack.shrink sp).push f

/-- Execute `x` and concatenate generated Format objects. -/
def concat (x : FormatterM Unit) : FormatterM Unit := do
  fold (Array.foldl (fun acc f => if acc.isNil then f else f ++ acc) Format.nil) x

def indent (x : Formatter) (indent : Option Int := none) : Formatter := do
  concat x
  let ctx ← read
  let indent := indent.getD $ Format.getIndent ctx.options
  modify fun st => { st with stack := st.stack.pop.push (Format.nest indent st.stack.back) }

def group (x : Formatter) : Formatter := do
  concat x
  modify fun st => { st with stack := st.stack.pop.push (Format.fill st.stack.back) }

@[combinatorFormatter Lean.Parser.orelse] def orelse.formatter (p1 p2 : Formatter) : Formatter :=
  -- HACK: We have no (immediate) information on which side of the orelse could have produced the current node, so try
  -- them in turn. Uses the syntax traverser non-linearly!
  p1 <|> p2

-- `mkAntiquot` is quite complex, so we'd rather have its formatter synthesized below the actual parser definition.
-- Note that there is a mutual recursion
-- `categoryParser -> mkAntiquot -> termParser -> categoryParser`, so we need to introduce an indirection somewhere
-- anyway.
@[extern "lean_mk_antiquot_formatter"]
constant mkAntiquot.formatter' (name : String) (kind : Option SyntaxNodeKind) (anonymous := true) : Formatter

def formatterForKind (k : SyntaxNodeKind) : Formatter := do
  let env ← getEnv
  let p::_ ← pure $ formatterAttribute.getValues env k
    | throwError! "no known formatter for kind '{k}'"
  p

@[combinatorFormatter Lean.Parser.withAntiquot]
def withAntiquot.formatter (antiP p : Formatter) : Formatter :=
  -- TODO: could be optimized using `isAntiquot` (which would have to be moved), but I'd rather
  -- fix the backtracking hack outright.
  orelse.formatter antiP p

@[combinatorFormatter Lean.Parser.categoryParser]
def categoryParser.formatter (cat : Name) : Formatter := group $ indent do
  let stx ← getCur
  if stx.getKind == `choice then
    visitArgs do
      let stx ← getCur;
      let sp ← getStackSize
      stx.getArgs.forM fun stx => formatterForKind stx.getKind
      let stack ← getStack
      if stack.size > sp && stack.anyRange sp stack.size fun f => f.pretty != (stack.get! sp).pretty then
        panic! "Formatter.visit: inequal choice children";
      -- discard all but one child format
      setStack $ stack.extract 0 (sp+1)
  else
    withAntiquot.formatter (mkAntiquot.formatter' cat.toString none) (formatterForKind stx.getKind)

@[combinatorFormatter Lean.Parser.categoryParserOfStack]
def categoryParserOfStack.formatter (offset : Nat) : Formatter := do
  let st ← get
  let stx := st.stxTrav.parents.back.getArg (st.stxTrav.idxs.back - offset)
  categoryParser.formatter stx.getId

@[combinatorFormatter Lean.Parser.error]
def error.formatter (msg : String) : Formatter := pure ()
@[combinatorFormatter Lean.Parser.try]
def try.formatter (p : Formatter) : Formatter := p
@[combinatorFormatter Lean.Parser.lookahead]
def lookahead.formatter (p : Formatter) : Formatter := pure ()

@[combinatorFormatter Lean.Parser.notFollowedBy]
def notFollowedBy.formatter (p : Formatter) : Formatter := pure ()

@[combinatorFormatter Lean.Parser.andthen]
def andthen.formatter (p1 p2 : Formatter) : Formatter := p2 *> p1

def checkKind (k : SyntaxNodeKind) : FormatterM Unit := do
  let stx ← getCur
  if k != stx.getKind then
    trace[PrettyPrinter.format.backtrack]! "unexpected node kind '{stx.getKind}', expected '{k}'"
    throwBacktrack

@[combinatorFormatter Lean.Parser.node]
def node.formatter (k : SyntaxNodeKind) (p : Formatter) : Formatter := do
  checkKind k;
  visitArgs p

@[combinatorFormatter Lean.Parser.trailingNode]
def trailingNode.formatter (k : SyntaxNodeKind) (_ : Nat) (p : Formatter) : Formatter := do
  checkKind k
  visitArgs do
    p;
    -- leading term, not actually produced by `p`
    categoryParser.formatter `foo

def parseToken (s : String) : FormatterM ParserState := do
  let ctx ← read
  let env ← getEnv
  pure $ Parser.tokenFn { input := s, fileName := "", fileMap := FileMap.ofString "", prec := 0, env := env, tokens := ctx.table } (Parser.mkParserState s)

def pushTokenCore (tk : String) : FormatterM Unit := do
  if tk.toSubstring.dropRightWhile (fun s => s == ' ') == tk.toSubstring then
    push tk
  else
    pushLine
    push tk.trimRight

def pushToken (tk : String) : FormatterM Unit := do
  let st ← get
  -- If there is no space between `tk` and the next word, compare parsing `tk` with and without the next word
  if st.leadWord != "" && tk.trimRight == tk then
    let t1 ← parseToken tk.trimLeft
    let t2 ← parseToken $ tk.trimLeft ++ st.leadWord
    if t1.pos == t2.pos then
      -- same result => use `tk` as is, extend `leadWord` if not prefixed by whitespace
      pushTokenCore tk
      modify fun st => { st with leadWord := if tk.trimLeft == tk then tk ++ st.leadWord else "" }
    else
      -- different result => add space
      pushTokenCore $ tk ++ " "
      modify fun st => { st with leadWord := if tk.trimLeft == tk then tk else "" }
  else
    -- already separated => use `tk` as is
    pushTokenCore tk
    modify fun st => { st with leadWord := if tk.trimLeft == tk then tk else "" }

@[combinatorFormatter Lean.Parser.symbol]
def symbol.formatter (sym : String) : Formatter := do
  let stx ← getCur
  if stx.isToken sym then do
    pushToken sym;
    goLeft
  else do
    trace[PrettyPrinter.format.backtrack]! "unexpected syntax '{stx}', expected symbol '{sym}'"
    throwBacktrack

@[combinatorFormatter Lean.Parser.nonReservedSymbol] def nonReservedSymbol.formatter := symbol.formatter

@[combinatorFormatter Lean.Parser.unicodeSymbol]
def unicodeSymbol.formatter (sym asciiSym : String) : Formatter := do
  let stx ← getCur
  let Syntax.atom _ val ← pure stx
    | throwError $ "not an atom: " ++ toString stx
  if val == sym.trim then
    pushToken sym
  else
    pushToken asciiSym;
  goLeft

@[combinatorFormatter Lean.Parser.identNoAntiquot]
def identNoAntiquot.formatter : Formatter := do
  checkKind identKind;
  let stx ← getCur
  let id := stx.getId
  let id := id.simpMacroScopes
  let s := id.toString;
  if id.isAnonymous then
    pushToken "[anonymous]"
  else if isInaccessibleUserName id || id.components.any Name.isNum ||
    -- loose bvar
    "#".isPrefixOf s then
    -- not parsable anyway, output as-is
    pushToken s
  else
    -- try to parse `s` as-is; if it fails, escape
    let pst ← parseToken s
    if pst.stxStack == #[stx] then
      pushToken s
    else
      let n := stx.getId
      -- TODO: do something better than escaping all parts
      let n := (n.components.map fun c => "«" ++ toString c ++ "»").foldl mkNameStr Name.anonymous
      pushToken n.toString
  goLeft

@[combinatorFormatter Lean.Parser.rawIdent] def rawIdent.formatter : Formatter := do
  checkKind identKind
  let stx ← getCur
  pushToken stx.getId.toString;
  goLeft

@[combinatorFormatter Lean.Parser.identEq] def identEq.formatter (id : Name) := rawIdent.formatter

def visitAtom (k : SyntaxNodeKind) : Formatter := do
  let stx ← getCur
  if k != Name.anonymous then
    checkKind k
  let Syntax.atom _ val ← pure $ stx.ifNode (fun n => n.getArg 0) (fun _ => stx)
    | throwError $ "not an atom: " ++ toString stx
  pushToken val
  goLeft

@[combinatorFormatter Lean.Parser.charLitNoAntiquot] def charLitNoAntiquot.formatter := visitAtom charLitKind
@[combinatorFormatter Lean.Parser.strLitNoAntiquot] def strLitNoAntiquot.formatter := visitAtom strLitKind
@[combinatorFormatter Lean.Parser.nameLitNoAntiquot] def nameLitNoAntiquot.formatter := visitAtom nameLitKind
@[combinatorFormatter Lean.Parser.numLitNoAntiquot] def numLitNoAntiquot.formatter := visitAtom numLitKind
@[combinatorFormatter Lean.Parser.fieldIdx] def fieldIdx.formatter := visitAtom fieldIdxKind

@[combinatorFormatter Lean.Parser.many]
def many.formatter (p : Formatter) : Formatter := do
  let stx ← getCur
  visitArgs $ stx.getArgs.size.forM fun _ => p

@[combinatorFormatter Lean.Parser.many1] def many1.formatter (p : Formatter) : Formatter := many.formatter p

@[combinatorFormatter Lean.Parser.optional]
def optional.formatter (p : Formatter) : Formatter := visitArgs p

@[combinatorFormatter Lean.Parser.many1Unbox]
def many1Unbox.formatter (p : Formatter) : Formatter := do
  let stx ← getCur
  if stx.getKind == nullKind then do
    many.formatter p
  else
    p

@[combinatorFormatter Lean.Parser.sepBy]
def sepBy.formatter (p pSep : Formatter) : Formatter := do
  let stx ← getCur
  visitArgs $ (List.range stx.getArgs.size).reverse.forM $ fun i => if i % 2 == 0 then p else pSep

@[combinatorFormatter Lean.Parser.sepBy1] def sepBy1.formatter := sepBy.formatter

@[combinatorFormatter Lean.Parser.withPosition] def withPosition.formatter (p : Formatter) : Formatter := p
@[combinatorFormatter Lean.Parser.withoutPosition] def withoutPosition.formatter (p : Formatter) : Formatter := p
@[combinatorFormatter Lean.Parser.withForbidden] def withForbidden.formatter (tk : Token) (p : Formatter) : Formatter := p
@[combinatorFormatter Lean.Parser.withoutForbidden] def withoutForbidden.formatter (p : Formatter) : Formatter := p
@[combinatorFormatter Lean.Parser.setExpected]
def setExpected.formatter (expected : List String) (p : Formatter) : Formatter := p

@[combinatorFormatter Lean.Parser.toggleInsideQuot]
def toggleInsideQuot.formatter (p : Formatter) : Formatter := p

@[combinatorFormatter Lean.Parser.checkWsBefore] def checkWsBefore.formatter : Formatter := do
  let st ← get
  if st.leadWord != "" then
    pushLine

@[combinatorFormatter Lean.Parser.checkPrec] def checkPrec.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkStackTop] def checkStackTop.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkNoWsBefore] def checkNoWsBefore.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkTailWs] def checkTailWs.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkColGe] def checkColGe.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkColGt] def checkColGt.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkLineEq] def checkLineEq.formatter : Formatter := pure ()

@[combinatorFormatter Lean.Parser.eoi] def eoi.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.notFollowedByCategoryToken] def notFollowedByCategoryToken.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkNoImmediateColon] def checkNoImmediateColon.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkInsideQuot] def checkInsideQuot.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.checkOutsideQuot] def checkOutsideQuot.formatter : Formatter := pure ()
@[combinatorFormatter Lean.Parser.skip] def skip.formatter : Formatter := pure ()

@[combinatorFormatter Lean.Parser.pushNone] def pushNone.formatter : Formatter := goLeft

-- TODO: delete with old frontend
@[combinatorFormatter Lean.Parser.quotedSymbol] def quotedSymbol.formatter : Formatter := do
  checkKind quotedSymbolKind
  visitArgs do
    push "`"; goLeft
    visitAtom Name.anonymous
    push "`"; goLeft

@[combinatorFormatter Lean.Parser.interpolatedStr]
def interpolatedStr.formatter (p : Formatter) : Formatter := do
  visitArgs $ (← getCur).getArgs.reverse.forM fun chunk =>
    match chunk.isLit? interpolatedStrLitKind with
    | some str => push str *> goLeft
    | none     => p

@[combinatorFormatter Lean.Parser.unquotedSymbol] def unquotedSymbol.formatter := visitAtom Name.anonymous

@[combinatorFormatter ite, macroInline] def ite {α : Type} (c : Prop) [h : Decidable c] (t e : Formatter) : Formatter :=
  if c then t else e

end Formatter
open Formatter

def format (formatter : Formatter) (stx : Syntax) : CoreM Format := do
let options ← getOptions
let table ← Parser.builtinTokenTable.get
catchInternalId backtrackExceptionId
  (do
    let (_, st) ← (concat formatter { table := table, options := options }).run { stxTrav := Syntax.Traverser.fromSyntax stx };
    pure $ Format.fill $ st.stack.get! 0)
  (fun _ => throwError "format: uncaught backtrack exception")

def formatTerm := format $ categoryParser.formatter `term
def formatCommand := format $ categoryParser.formatter `command

builtin_initialize registerTraceClass `PrettyPrinter.format;

end PrettyPrinter
end Lean

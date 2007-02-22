--  C -> Haskell Compiler: Parser for C Header Files
--
--  Author : Manuel M T Chakravarty, Duncan Coutts
--  Created: 29 May 2005
--
--  Version $Revision: 1.1.2.1 $ from $Date: 2005/06/14 00:16:15 $
--
--  Copyright (c) [1999..2004] Manuel M T Chakravarty
--  Copyright (c) 2005 Duncan Coutts
--
--  This file is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This file is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--- DESCRIPTION ---------------------------------------------------------------
--
--  Parser for C header files, which have already been run through the C
--  preprocessor.  
--
--- DOCU ----------------------------------------------------------------------
--
--  language: Haskell 98
--
--  The parser recognizes all of ANCI C.  The parser combinators follow K&R
--  Appendix A, but we make use of the richer grammar constructs provided by
--  `Parsers'.  It supports the C99 `restrict' extension and `inline'.  The
--  parser is rather permissive with respect to the formation of declarators
--  in function definitions (it doesn't enforce strict function syntax).
--  Non-complying definitions need to be detected by subsequent passes if
--  strict checking is required.
--
--  Comments:
--
--  * Subtrees representing empty declarators of the form `CVarDeclr Nothing
--    at' have *no* valid attribute handle in `at' (only a `newAttrsOnlyPos
--    nopos').
--
--  * Details on the C99 restrict extension are at:
--    <http://www.lysator.liu.se/c/restrict.html>.
--
--  With K&R we refer to ``The C Programming Language'', second edition, Brain
--  W. Kernighan and Dennis M. Ritchie, Prentice Hall, 1988.
--
--  Supported GNU C extensions:
--
--  * We also recognize GNU C `__attribute__' annotations (however, they are
--    not entered into the structure tree, but ignored).  More specifically, 
--
--      '__attribute__' '(' '(' attr ')' ')'
--
--    may occur after declarator specifiers or after a declarator itself (only
--    meaningful if it is a typedef), where `attr' is either just an 
--    identifier or an identifier followed by a comma-separated list of
--    constant expressions as follows:
--
--      attr  -> id ['(' const_1 ',' ... ',' const_n ')']
--	       | 'const'
--	const -> <constant expression>
--
--  * We also recognize GNU C `__extension__' annotations (however, they are
--    not entered into the structure tree, but ignored).  More specifically, 
--
--      __extension__
--
--    may occur in a specifier list.
--
--  * There may be a `,' behind the last element of a enum.
--
--  * Structs and unions may lack any declarations; eg, `struct { } foo;' is
--    valid. 
--
--  * Builtin type names are imported from `CBuiltin'.
--
--- TODO ----------------------------------------------------------------------
--

{
module CParser (parseC) where

import Monad	  (when)
import Maybe      (catMaybes)

import Position   (Position, Pos(..), nopos)
import UNames     (Name, NameSupply, names)
import Idents     (Ident)
import Attributes (Attrs, newAttrs, newAttrsOnlyPos)

import State      (PreCST, raiseFatal, getNameSupply)
import CLexer     (lexC, parseError)
import CAST       (CHeader(..), CExtDecl(..), CFunDef(..), CStat(..),
		   CDecl(..), CDeclSpec(..), CStorageSpec(..), CTypeSpec(..),
		   CTypeQual(..), CStructUnion(..), CStructTag(..), CEnum(..),
		   CDeclr(..), CInit(..), CExpr(..), CAssignOp(..),
		   CBinaryOp(..), CUnaryOp(..), CConst (..))
import CBuiltin   (builtinTypeNames)
import CTokens    (CToken(..), GnuCTok(..))
import CParserMonad (P, execParser, getNewName, addTypedef)
}

%name header header
%tokentype { CToken }

%monad { P } { >>= } { return }
%lexer { lexC } { CTokEof }

-- precedence to avoid a shift/reduce conflict in the "if then else" syntax.
%nonassoc if
%nonassoc else

%token

'('		{ CTokLParen	_ }
')'		{ CTokRParen	_ }
'['		{ CTokLBracket	_ }
']'		{ CTokRBracket	_ }
"->"		{ CTokArrow	_ }
'.'		{ CTokDot	_ }
'!'		{ CTokExclam	_ }
'~'		{ CTokTilde	_ }
"++"		{ CTokInc	_ }
"--"		{ CTokDec	_ }
'+'		{ CTokPlus	_ }
'-'		{ CTokMinus	_ }
'*'		{ CTokStar	_ }
'/'		{ CTokSlash	_ }
'%'		{ CTokPercent	_ }
'&'		{ CTokAmper	_ }
"<<"		{ CTokShiftL	_ }
">>"		{ CTokShiftR	_ }
'<'		{ CTokLess	_ }
"<="		{ CTokLessEq	_ }
'>'		{ CTokHigh	_ }
">="		{ CTokHighEq	_ }
"=="		{ CTokEqual	_ }
"!="		{ CTokUnequal	_ }
'^'		{ CTokHat	_ }
'|'		{ CTokBar	_ }
"&&"		{ CTokAnd	_ }
"||"		{ CTokOr	_ }
'?'		{ CTokQuest	_ }
':'		{ CTokColon	_ }
'='		{ CTokAssign	_ }
"+="		{ CTokPlusAss	_ }
"-="		{ CTokMinusAss	_ }
"*="		{ CTokStarAss	_ }
"/="		{ CTokSlashAss	_ }
"%="		{ CTokPercAss	_ }
"&="		{ CTokAmpAss	_ }
"^="		{ CTokHatAss	_ }
"|="		{ CTokBarAss	_ }
"<<="		{ CTokSLAss	_ }
">>="		{ CTokSRAss	_ }
','		{ CTokComma	_ }
';'		{ CTokSemic	_ }
'{'		{ CTokLBrace	_ }
'}'		{ CTokRBrace	_ }
"..."		{ CTokEllipsis	_ }
alignof		{ CTokAlignof	_ }
asm		{ CTokAsm	_ }
auto		{ CTokAuto	_ }
break		{ CTokBreak	_ }
case		{ CTokCase	_ }
char		{ CTokChar	_ }
const		{ CTokConst	_ }
continue	{ CTokContinue	_ }
default		{ CTokDefault	_ }
do		{ CTokDo	_ }
double		{ CTokDouble	_ }
else		{ CTokElse	_ }
enum		{ CTokEnum	_ }
extern		{ CTokExtern	_ }
float		{ CTokFloat	_ }
for		{ CTokFor	_ }
goto		{ CTokGoto	_ }
if		{ CTokIf	_ }
inline		{ CTokInline	_ }
int		{ CTokInt	_ }
long		{ CTokLong	_ }
register	{ CTokRegister	_ }
restrict	{ CTokRestrict	_ }
return		{ CTokReturn	_ }
short		{ CTokShort	_ }
signed		{ CTokSigned	_ }
sizeof		{ CTokSizeof	_ }
static		{ CTokStatic	_ }
struct		{ CTokStruct	_ }
switch		{ CTokSwitch	_ }
typedef		{ CTokTypedef	_ }
union		{ CTokUnion	_ }
unsigned	{ CTokUnsigned	_ }
void		{ CTokVoid	_ }
volatile	{ CTokVolatile	_ }
while		{ CTokWhile	_ }
cchar		{ CTokCLit   _ _ }		-- character constant
cint		{ CTokILit   _ _ }		-- integer constant
cfloat		{ CTokFLit   _ _ }		-- float constant
cstr		{ CTokSLit   _ _ }		-- string constant (no escapes)
ident		{ CTokIdent  _ $$ }		-- identifier
tyident		{ CTokTyIdent _ $$ }		-- `typedef-name' identifier
attribute	{ CTokGnuC GnuCAttrTok _ }	-- special GNU C tokens
extension	{ CTokGnuC GnuCExtTok  _ }	-- special GNU C tokens

%%


-- parse a complete C header file
--
header :: { CHeader }
header
  : translation_unit	{% withAttrs $1 $ CHeader (reverse $1) }


-- parse a complete C translation unit (C99 6.9)
--
translation_unit :: { [CExtDecl] }
translation_unit
  : {- empty -}					{ [] }
  | translation_unit external_declaration	{ $2 : $1 }
  | translation_unit asm '(' expression ')' ';'
	{% withAttrs $2 $ \at -> CAsmExt at : $1 }


-- parse external C declaration (C99 6.9)
--
external_declaration :: { CExtDecl }
external_declaration
  : function_definition			{ CFDefExt $1 }
  | declaration ';'			{ CDeclExt $1 }
  | extension external_declaration	{ $2 }


-- parse C function definition (C99 6.9.1)
--
function_definition :: { CFunDef }
function_definition
  : declaration_specifiers declarator declaration_list compound_statement
	{% withAttrs $1 $ CFunDef $1 $2 (reverse $3) $4 }

  | declarator declaration_list compound_statement
  	{% withAttrs $1 $ CFunDef [] $1 (reverse $2) $3 }


-- parse C statement (C99 6.8)
--
statement :: { CStat }
statement
  : labeled_statement			{ $1 }
  | compound_statement			{ $1 }
  | expression_statement		{ $1 }
  | selection_statement			{ $1 }
  | iteration_statement			{ $1 }
  | jump_statement			{ $1 }
  | asm_statement			{ $1 }


statement_list :: { [CStat] }
statement_list
  : {- empty -}			{ [] }
  | statement_list statement	{ $2 : $1 }


-- parse C labeled statement (C99 6.8.1)
--
labeled_statement :: { CStat }
labeled_statement
  : ident ':' statement				{% withAttrs $2 $ CLabel $1 $3}
  | case constant_expression ':' statement	{% withAttrs $1 $ CCase $2 $4 }
  | default ':' statement			{% withAttrs $1 $ CDefault $3 }


-- parse C expression statement (C99 6.8.3)
--
expression_statement :: { CStat }
expression_statement
  : ';'				{% withAttrs $1 $ CExpr Nothing }
  | expression ';'		{% withAttrs $1 $ CExpr (Just $1) }


-- parse C compound statement (C99 6.8.2)
--
compound_statement :: { CStat }
compound_statement
  : '{' declaration_list statement_list '}'
  	{% withAttrs $1 $ CCompound (reverse $2) (reverse $3) }


-- parse C selection statement (C99 6.8.4)
--
selection_statement :: { CStat }
selection_statement
  : if '(' expression ')' statement %prec if
	{% withAttrs $1 $ CIf $3 $5 Nothing }

  | if '(' expression ')' statement else statement
	{% withAttrs $1 $ CIf $3 $5 (Just $7) }

  | switch '(' expression ')' statement	
	{% withAttrs $1 $ CSwitch $3 $5 }


-- parse C iteration statement (C99 6.8.5)
--
iteration_statement :: { CStat }
iteration_statement
  : while '(' expression ')' statement
  	{% withAttrs $1 $ CWhile $3 $5 False }

  | do statement while '(' expression ')' ';'
  	{% withAttrs $1 $ CWhile $5 $2 True }

  | for '(' expression_statement expression_statement ')' statement
  	{% withAttrs $1 $ case $3 of
	                    CExpr e3 _ ->
			      case $4 of
			        CExpr e4 _ -> CFor e3 e4 Nothing $6 }

  | for '(' expression_statement expression_statement expression ')' statement
  	{% withAttrs $1 $ case $3 of
	                    CExpr e3 _ ->
			      case $4 of
			        CExpr e4 _ -> CFor e3 e4 (Just $5) $7 }


-- parse C jump statement (C99 6.8.6)
--
jump_statement :: { CStat }
jump_statement
  : goto ident ';'			{% withAttrs $1 $ CGoto $2 }
  | continue ';'			{% withAttrs $1 $ CCont }
  | break ';'				{% withAttrs $1 $ CBreak }
  | return ';'				{% withAttrs $1 $ CReturn Nothing }
  | return expression ';'		{% withAttrs $1 $ CReturn (Just $2) }


-- parse GNU C __asm__ (...) statement (recording only a place holder result)
--
asm_statement :: { CStat }
asm_statement
  : asm maybe_type_qualifier '(' expression ')' ';'
  	{% withAttrs $1 CAsm }
  | asm maybe_type_qualifier '(' expression ':' asm_operands ')' ';'
  	{% withAttrs $1 CAsm }
  | asm maybe_type_qualifier '(' expression ':' asm_operands
					    ':' asm_operands ')' ';'
  	{% withAttrs $1 CAsm }
  | asm maybe_type_qualifier '(' expression ':' asm_operands ':' asm_operands
					    ':' asm_clobbers ')' ';'
  	{% withAttrs $1 CAsm }

maybe_type_qualifier :: { () }
maybe_type_qualifier
  : {- empty -}		{ () }
  | type_qualifier	{ () }


asm_operands :: { () }
asm_operands
  : {- empty -}				{ () }
  | nonnull_asm_operands		{ () }


nonnull_asm_operands :: { () }
nonnull_asm_operands
  : asm_operand					{ () }
  | nonnull_asm_operands ',' asm_operand	{ () }


asm_operand :: { () }
asm_operand
  : string '(' expression ')'			{ () }
  | '[' ident ']' string '(' expression ')'	{ () }
  | '[' tyident ']' string '(' expression ')'	{ () }


asm_clobbers :: { () }
asm_clobbers
  : string			{ () }
  | asm_clobbers ',' string	{ () }


-- parse C declaration (C99 6.7)
--
-- * We allow the GNU C extension keyword before a declaration and GNU C
--   attribute annotations after declaration specifiers, but they are not
--   entered into the structure tree.
--
declaration :: { CDecl }
declaration
  : declaration_specifiers
  	{% withAttrs $1 $ CDecl $1 [] }

  | declaration_specifiers init_declarator_list
	{% let declrs = reverse $2
	    in when (isTypeDef $1)
	            (mapM_ addTypedef (getTypeDefIdents (map fst declrs)))
	    >> getNewName >>= \name ->
	       let attrs = newAttrs (posOf $1) name
	           declrs' = [ (Just d, i, Nothing) | (d, i) <- declrs ]
	        in attrs `seq`
	           return (CDecl $1 declrs' attrs) }


declaration_list :: { [CDecl] }
declaration_list
  : {- empty -}					{ [] }
  | declaration_list declaration ';'		{ $2 : $1 }


-- parse C declaration specifiers (C99 6.7)
--
declaration_specifiers :: { [CDeclSpec] }
declaration_specifiers
  : storage_class_specifier
  	{ [CStorageSpec $1] }

  | storage_class_specifier declaration_specifiers
  	{ CStorageSpec $1 : $2 }

  | type_specifier
  	{ [CTypeSpec $1] }

  | type_specifier declaration_specifiers
  	{ CTypeSpec $1 : $2 }

  | type_qualifier
  	{ [CTypeQual $1] }

  | type_qualifier declaration_specifiers
  	{ CTypeQual $1 : $2 }


-- parse C init declarator (C99 6.7)
--
init_declarator :: { (CDeclr, Maybe CInit) }
init_declarator
  : declarator maybe_asm				{ ($1, Nothing) }
  | declarator maybe_asm '=' initializer		{ ($1, Just $4) }


maybe_asm :: { () }
maybe_asm
  : {- empty -}		{ () }
  | asm '(' string ')'	{ () }


init_declarator_list :: { [(CDeclr, Maybe CInit)] }
init_declarator_list
  : init_declarator					{ [$1] }
  | init_declarator_list ',' init_declarator		{ $3 : $1 }


-- parse C storage class specifier (C99 6.7.1)
--
storage_class_specifier :: { CStorageSpec }
storage_class_specifier
  : typedef			{% withAttrs $1 $ CTypedef }
  | extern			{% withAttrs $1 $ CExtern }
  | static			{% withAttrs $1 $ CStatic }
  | auto			{% withAttrs $1 $ CAuto }
  | register			{% withAttrs $1 $ CRegister }


-- parse C type specifier (K&R A8.2)
--
type_specifier :: { CTypeSpec }
type_specifier
  : void			{% withAttrs $1 $ CVoidType }
  | char			{% withAttrs $1 $ CCharType }
  | short			{% withAttrs $1 $ CShortType }
  | int				{% withAttrs $1 $ CIntType }
  | long			{% withAttrs $1 $ CLongType }
  | float			{% withAttrs $1 $ CFloatType }
  | double			{% withAttrs $1 $ CDoubleType }
  | signed			{% withAttrs $1 $ CSignedType }
  | unsigned			{% withAttrs $1 $ CUnsigType }
  | struct_or_union_specifier	{% withAttrs $1 $ CSUType $1 }
  | enum_specifier		{% withAttrs $1 $ CEnumType $1 }
  | tyident			{% withAttrs $1 $ CTypeDef $1 }


-- parse C type qualifier (C99 6.7.3)
--
type_qualifier :: { CTypeQual }
type_qualifier
  : const		{% withAttrs $1 $ CConstQual }
  | volatile		{% withAttrs $1 $ CVolatQual }
  | restrict		{% withAttrs $1 $ CRestrQual }
  | inline		{% withAttrs $1 $ CInlinQual }


-- parse C structure of union declaration (C99 6.7.2.1)
--
-- * Note: an identifier after a struct tag *may* be a type name; thus, we need
--	   to use `tyident' as well rather than just `ident'
--
-- * GNU C: Structs and unions may lack any declarations; eg, `struct { }
--   foo;' is valid. 
--
struct_or_union_specifier :: { CStructUnion }
struct_or_union_specifier
  : struct_or_union ident '{' struct_declaration_list '}'
  	{% withAttrs $1 $ CStruct (unL $1) (Just $2) (reverse $4) }

  | struct_or_union tyident '{' struct_declaration_list '}'
  	{% withAttrs $1 $ CStruct (unL $1) (Just $2) (reverse $4) }

  | struct_or_union '{' struct_declaration_list '}'
  	{% withAttrs $1 $ CStruct (unL $1) Nothing   (reverse $3) }

  | struct_or_union ident
  	{% withAttrs $1 $ CStruct (unL $1) (Just $2) [] }

  | struct_or_union tyident
  	{% withAttrs $1 $ CStruct (unL $1) (Just $2) [] }


struct_or_union :: { Located CStructTag }
struct_or_union
  : struct			{ L CStructTag (posOf $1) }
  | union			{ L CUnionTag (posOf $1) }


struct_declaration_list :: { [CDecl] }
struct_declaration_list
  : {- empty -}						{ [] }
  | struct_declaration_list struct_declaration		{ $2 : $1 }


-- parse C structure declaration (C99 6.7.2.1)
--
-- * We allow the GNU C extension keyword before a declaration, but it is
--   not entered into the structure tree.
--
struct_declaration :: { CDecl }
struct_declaration
  : specifier_qualifier_list struct_declarator_list ';'
  	{% withAttrs $1 $ CDecl $1 [(d,Nothing,s) | (d,s) <- reverse $2] }

  | extension struct_declaration	{ $2 }


-- parse C specifier qualifier (K&R A8.3)
--
specifier_qualifier_list :: { [CDeclSpec] }
specifier_qualifier_list
  : type_specifier				{ [CTypeSpec $1] }
  | type_specifier specifier_qualifier_list	{ CTypeSpec $1 : $2 }
  | type_qualifier				{ [CTypeQual $1] }
  | type_qualifier specifier_qualifier_list	{ CTypeQual $1 : $2 }


-- parse C structure declarator (K&R A8.3)
--
struct_declarator :: { (Maybe CDeclr, Maybe CExpr) }
struct_declarator
  : declarator					{ (Just $1, Nothing) }
  | ':' constant_expression			{ (Nothing, Just $2) }
  | declarator ':' constant_expression		{ (Just $1, Just $3) }


struct_declarator_list :: { [(Maybe CDeclr, Maybe CExpr)] }
struct_declarator_list
  : struct_declarator					{ [$1] }
  | struct_declarator_list ',' struct_declarator	{ $3 : $1 }


-- parse C enumeration declaration (C99 6.7.2.2)
--
--  * There may be a `,' behind the last element of a enum.
--
enum_specifier :: { CEnum }
enum_specifier
  : enum '{' enumerator_list '}'
  	{% withAttrs $1 $ CEnum Nothing   (reverse $3) }

  | enum ident '{' enumerator_list '}'
  	{% withAttrs $1 $ CEnum (Just $2) (reverse $4) }

  | enum ident
  	{% withAttrs $1 $ CEnum (Just $2) []           }


enumerator_list :: { [(Ident,	Maybe CExpr)] }
enumerator_list
  : enumerator_list_				{ $1 }
  | enumerator_list_ ','			{ $1 }


enumerator_list_ :: { [(Ident,	Maybe CExpr)] }
enumerator_list_
  : enumerator					{ [$1] }
  | enumerator_list_ ',' enumerator		{ $3 : $1 }


enumerator :: { (Ident,	Maybe CExpr) }
enumerator
  : ident					{ ($1, Nothing) }
  | ident '=' constant_expression		{ ($1, Just $3) }


-- parse C declarator (C99 6.7.5)
--
-- * We allow GNU C attribute annotations at the end of a declerator,
--   but they are not entered into the structure tree.
--
declarator :: { CDeclr }
declarator
  : pointer direct_declarator
  	{% withAttrs $1 $ CPtrDeclr (map unL $1) $2 }

  | direct_declarator
  	{ $1 }


direct_declarator :: { CDeclr }
direct_declarator
  : ident
  	{% withAttrs $1 $ CVarDeclr (Just $1) }

  | '(' declarator ')'
  	{ $2 }

  | direct_declarator '[' constant_expression ']'
  	{% withAttrs $2 $ CArrDeclr $1 (Just $3) }

  | direct_declarator '[' ']'
  	{% withAttrs $2 $ CArrDeclr $1  Nothing  }

  | direct_declarator '(' parameter_type_list ')'
  	{% withAttrs $2 $ case $3 of
	                    (parms, variadic) -> CFunDeclr $1 parms variadic }

  | direct_declarator '(' identifier_list ')'
  	{% withAttrs $2 $ CFunDeclr $1 [] False }


identifier_list :: { () }
identifier_list
  : ident				{ () }
  | identifier_list ',' ident		{ () }


pointer :: { [Located [CTypeQual]] }
pointer
  : '*' type_qualifier_list		{ [L (reverse $2) (posOf $1)] }
  | '*' type_qualifier_list pointer	{  L (reverse $2) (posOf $1) : $3 }


type_qualifier_list :: { [CTypeQual] }
type_qualifier_list
  : {- empty -}				{ [] }
  | type_qualifier_list type_qualifier	{ $2 : $1 }


parameter_type_list :: { ([CDecl], Bool) }
parameter_type_list
  : {- empty -}				{ ([], False)}
  | parameter_list			{ (reverse $1, False) }
  | parameter_list ',' "..."		{ (reverse $1, True) }


-- parse C parameter type list (C99 6.7.5)
--
parameter_list :: { [CDecl] }
parameter_list
  : parameter_declaration			{ [$1] }
  | parameter_list ',' parameter_declaration	{ $3 : $1 }


parameter_declaration :: { CDecl }
parameter_declaration
  : declaration_specifiers declarator
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  | declaration_specifiers abstract_declarator
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  | declaration_specifiers
  	{% withAttrs $1 $ CDecl $1 [] }


-- parse C initializer (C99 6.7.8)
--
initializer :: { CInit }
initializer
  : assignment_expression		{% withAttrs $1 $ CInitExpr $1 }
  | '{' initializer_list '}'		{% withAttrs $1 $ CInitList $2 }
  | '{' initializer_list ',' '}'	{% withAttrs $1 $ CInitList $2 }


initializer_list :: { [CInit] }
initializer_list
  : initializer				{ [$1] }
  | initializer_list ',' initializer	{ $3 : $1 }


-- parse C type name (C99 6.7.6)
--
type_name :: { CDecl }
type_name
  : specifier_qualifier_list
  	{% withAttrs $1 $ CDecl $1 [] }

  | specifier_qualifier_list abstract_declarator
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }


-- parse C abstract declarator (C99 6.7.6)
--
-- * following K&R, we do not allow old style function types (except empty
--   argument lists) in abstract declarators; unfortunately, gcc allows them
--
abstract_declarator :: { CDeclr }
abstract_declarator
  : pointer
  	{% withAttrs $1 $ CPtrDeclr (map unL $1) emptyDeclr }

  | direct_abstract_declarator
  	{ $1 }

  | pointer direct_abstract_declarator
  	{% withAttrs $1 $ CPtrDeclr (map unL $1) $2 }


direct_abstract_declarator :: { CDeclr }
direct_abstract_declarator
  : '(' abstract_declarator ')'
  	{ $2 }

  | '[' ']'
  	{% withAttrs $1 $ CArrDeclr emptyDeclr  Nothing  }

  | '[' constant_expression ']'
  	{% withAttrs $1 $ CArrDeclr emptyDeclr (Just $2) }

  | direct_abstract_declarator '[' ']'
  	{% withAttrs $2 $ CArrDeclr $1  Nothing  }

  | direct_abstract_declarator '[' constant_expression ']'
  	{% withAttrs $2 $ CArrDeclr $1 (Just $3) }

  | '(' parameter_type_list ')'
  	{% withAttrs $1 $ case $2 of
	                    (parms, variadic) ->
			      CFunDeclr emptyDeclr parms variadic }

  | direct_abstract_declarator '(' parameter_type_list ')'
  	{% withAttrs $2 $ case $3 of (parms, variadic) -> CFunDeclr $1 parms variadic }


-- parse C primary expression (C99 6.5.1)
--
-- * contrary to K&R, we regard parsing strings as parsing constants
--
primary_expression :: { CExpr }
primary_expression
  : ident		{% withAttrs $1 $ CVar $1 }
  | literal_expression	{% withAttrs $1 $ CConst $1 }
  | '(' expression ')'	{ $2 }


--parse C postfix expression (C99 6.5.2)
--
postfix_expression :: { CExpr }
postfix_expression
  : primary_expression
  	{ $1 }

  | postfix_expression '[' expression ']'
  	{% withAttrs $2 $ CIndex $1 $3 }

  | postfix_expression '(' ')'
  	{% withAttrs $2 $ CCall $1 [] }

  | postfix_expression '(' argument_expression_list ')'
  	{% withAttrs $2 $ CCall $1 (reverse $3) }

  | postfix_expression '.' ident
  	{% withAttrs $2 $ CMember $1 $3 False }

  | postfix_expression "->" ident
  	{% withAttrs $2 $ CMember $1 $3 True }

  | postfix_expression "++"
  	{% withAttrs $2 $ CUnary CPostIncOp $1 }

  | postfix_expression "--"
  	{% withAttrs $2 $ CUnary CPostDecOp $1 }

  | '(' type_name ')' '{' initializer_list '}'
  	{% withAttrs $2 $ CCompoundLit $5 }

  | '(' type_name ')' '{' initializer_list ',' '}'
  	{% withAttrs $2 $ CCompoundLit $5 }

argument_expression_list :: { [CExpr] }
argument_expression_list
  : assignment_expression				{ [$1] }
  | argument_expression_list ',' assignment_expression	{ $3 : $1 }


-- parse C unary expression (C99 6.5.3)
--
-- * GNU extension: `alignof'
--
unary_expression :: { CExpr }
unary_expression
  : postfix_expression			{ $1 }
  | "++" unary_expression		{% withAttrs $1 $ CUnary CPreIncOp $2 }
  | "--" unary_expression		{% withAttrs $1 $ CUnary CPreDecOp $2 }
  | extension cast_expression		{ $2 }
  | unary_operator cast_expression	{% withAttrs $1 $ CUnary (unL $1) $2 }
  | sizeof unary_expression		{% withAttrs $1 $ CSizeofExpr $2 }
  | sizeof '(' type_name ')'		{% withAttrs $1 $ CSizeofType $3 }
  | alignof unary_expression		{% withAttrs $1 $ CAlignofExpr $2 }
  | alignof '(' type_name ')'		{% withAttrs $1 $ CAlignofType $3 }


unary_operator :: { Located CUnaryOp }
unary_operator
  : '&'		{ L CAdrOp (posOf $1) }
  | '*'		{ L CIndOp (posOf $1) }
  | '+'		{ L CPlusOp (posOf $1) }
  | '-'		{ L CMinOp (posOf $1) }
  | '~'		{ L CCompOp (posOf $1) }
  | '!'		{ L CNegOp (posOf $1) }


-- parse C cast expression (C99 6.5.4)
--
cast_expression :: { CExpr }
cast_expression
  : unary_expression			{ $1 }
  | '(' type_name ')' cast_expression	{% withAttrs $1 $ CCast $2 $4 }


-- parse C multiplicative expression (C99 6.5.5)
--
multiplicative_expression :: { CExpr }
multiplicative_expression
  : cast_expression
  	{ $1 }

  | multiplicative_expression '*' cast_expression
  	{% withAttrs $2 $ CBinary CMulOp $1 $3 }

  | multiplicative_expression '/' cast_expression
  	{% withAttrs $2 $ CBinary CDivOp $1 $3 }

  | multiplicative_expression '%' cast_expression
  	{% withAttrs $2 $ CBinary CRmdOp $1 $3 }


-- parse C additive expression (C99 6.5.6)
--
additive_expression :: { CExpr }
additive_expression
  : multiplicative_expression
  	{ $1 }

  | additive_expression '+' multiplicative_expression
  	{% withAttrs $2 $ CBinary CAddOp $1 $3 }

  | additive_expression '-' multiplicative_expression
  	{% withAttrs $2 $ CBinary CSubOp $1 $3 }


-- parse C shift expression (C99 6.5.7)
--
shift_expression :: { CExpr }
shift_expression
  : additive_expression
  	{ $1 }

  | shift_expression "<<" additive_expression
  	{% withAttrs $2 $ CBinary CShlOp $1 $3 }

  | shift_expression ">>" additive_expression
  	{% withAttrs $2 $ CBinary CShrOp $1 $3 }


-- parse C relational expression (C99 6.5.8)
--
relational_expression :: { CExpr }
relational_expression
  : shift_expression
  	{ $1 }

  | relational_expression '<' shift_expression
  	{% withAttrs $2 $ CBinary CLeOp $1 $3 }

  | relational_expression '>' shift_expression
  	{% withAttrs $2 $ CBinary CGrOp $1 $3 }

  | relational_expression "<=" shift_expression
  	{% withAttrs $2 $ CBinary CLeqOp $1 $3 }

  | relational_expression ">=" shift_expression
  	{% withAttrs $2 $ CBinary CGeqOp $1 $3 }


-- parse C equality expression (C99 6.5.9)
--
equality_expression :: { CExpr }
equality_expression
  : relational_expression
  	{ $1 }

  | equality_expression "==" relational_expression
  	{% withAttrs $2 $ CBinary CEqOp  $1 $3 }

  | equality_expression "!=" relational_expression
  	{% withAttrs $2 $ CBinary CNeqOp $1 $3 }


-- parse C bitwise and expression (C99 6.5.10)
--
and_expression :: { CExpr }
and_expression
  : equality_expression
  	{ $1 }

  | and_expression '&' equality_expression
  	{% withAttrs $2 $ CBinary CAndOp $1 $3 }


-- parse C bitwise exclusive or expression (C99 6.5.11)
--
exclusive_or_expression :: { CExpr }
exclusive_or_expression
  : and_expression
  	{ $1 }

  | exclusive_or_expression '^' and_expression
  	{% withAttrs $2 $ CBinary CXorOp $1 $3 }


-- parse C bitwise or expression (C99 6.5.12)
--
inclusive_or_expression :: { CExpr }
inclusive_or_expression
  : exclusive_or_expression
  	{ $1 }

  | inclusive_or_expression '|' exclusive_or_expression
  	{% withAttrs $2 $ CBinary COrOp $1 $3 }


-- parse C logical and expression (C99 6.5.13)
--
logical_and_expression :: { CExpr }
logical_and_expression
  : inclusive_or_expression
  	{ $1 }

  | logical_and_expression "&&" inclusive_or_expression
  	{% withAttrs $2 $ CBinary CLndOp $1 $3 }


-- parse C logical or expression (C99 6.5.14)
--
logical_or_expression :: { CExpr }
logical_or_expression
  : logical_and_expression
  	{ $1 }

  | logical_or_expression "||" logical_and_expression
  	{% withAttrs $2 $ CBinary CLorOp $1 $3 }


-- parse C conditional expression (C99 6.5.15)
--
conditional_expression :: { CExpr }
conditional_expression
  : logical_or_expression
  	{ $1 }

  | logical_or_expression '?' expression ':' conditional_expression
  	{% withAttrs $2 $ CCond $1 $3 $5 }


-- parse C assignment expression (C99 6.5.16)
--
assignment_expression :: { CExpr }
assignment_expression
  : conditional_expression
  	{ $1 }

  | unary_expression assignment_operator assignment_expression
  	{% withAttrs $2 $ CAssign (unL $2) $1 $3 }


assignment_operator :: { Located CAssignOp }
assignment_operator
  : '='			{ L CAssignOp (posOf $1) }
  | "*="		{ L CMulAssOp (posOf $1) }
  | "/="		{ L CDivAssOp (posOf $1) }
  | "%="		{ L CRmdAssOp (posOf $1) }
  | "+="		{ L CAddAssOp (posOf $1) }
  | "-="		{ L CSubAssOp (posOf $1) }
  | "<<="		{ L CShlAssOp (posOf $1) }
  | ">>="		{ L CShrAssOp (posOf $1) }
  | "&="		{ L CAndAssOp (posOf $1) }
  | "^="		{ L CXorAssOp (posOf $1) }
  | "|="		{ L COrAssOp  (posOf $1) }


-- parse C expression (C99 6.5.17)
--
expression :: { CExpr }
expression
  : expression_				{% case $1 of
					   [e] -> return e
					   _   -> let es = reverse $1 
					          in withAttrs es $ CComma es }

expression_ :: { [CExpr] }
expression_
  : assignment_expression			{ [$1] }
  | expression_ ',' assignment_expression	{ $3 : $1 }


-- parse C constant expression (C99 6.6)
--
constant_expression :: { CExpr }
constant_expression
  : conditional_expression			{ $1 }


-- parse C constants
--
-- * we include strings in constants
--
literal_expression :: { CConst }
literal_expression
  : cint	{% withAttrs $1 $ case $1 of CTokILit _ i -> CIntConst i }
  | cchar	{% withAttrs $1 $ case $1 of CTokCLit _ c -> CCharConst c }
  | cfloat	{% withAttrs $1 $ case $1 of CTokFLit _ f -> CFloatConst f }
  | string	{% withAttrs $1 $ CStrConst (unL $1) }


-- deal with C string liternal concatination
--
string :: { Located String }
string
  : cstr		{ case $1 of CTokSLit _ s -> L s (posOf $1) }
  | cstr string_	{ case $1 of CTokSLit _ s ->
                                       let s' = concat (s : reverse $2)
				        in L s' (posOf $1) }


string_ :: { [String] }
string_
  : cstr		{ case $1 of CTokSLit _ s -> [s] }
  | string_ cstr	{ case $2 of CTokSLit _ s -> s : $1 }

{-
-- parse GNU C attribute annotation (junking the result)
--
gnuc_attrs ::	{ () }
gnuc_attrs
  : {- empty -}						{ () }
  | gnuc_attrs gnuc_attribute_specifier			{ () }


gnuc_attrs_nonempty :: { () }
gnuc_attrs_nonempty
  : gnuc_attribute_specifier				{ () }
  | gnuc_attrs_nonempty gnuc_attribute_specifier	{ () }


gnuc_attribute_specifier :: { () }
gnuc_attribute_specifier
  : attribute '(' '(' gnuc_attribute_list ')' ')'	{ () }


gnuc_attribute_list :: { () }
  : gnuc_attribute					{ () } 
  | gnuc_attribute_list ',' gnuc_attribute		{ () } 


gnuc_attribute :: { () }
gnuc_attribute
  : {- empty -}						{ () }
  | ident						{ () }
  | const						{ () }
  | ident '(' gnuc_attribute_param_exps ')'		{ () }
  | ident '(' ')'					{ () }


gnuc_attribute_param_exps :: { () }
gnuc_attribute_param_exps
  : constant_expression					{ () }
  | gnuc_attribute_param_exps ',' constant_expression	{ () }
-}

{

data Located a = L !a !Position

unL :: Located a -> a
unL (L a pos) = a

instance Pos (Located a) where
  posOf (L _ pos) = pos

{-# INLINE withAttrs #-}
withAttrs :: Pos node => node -> (Attrs -> a) -> P a
withAttrs node mkAttributedNode = do
  name <- getNewName
  let attrs = newAttrs (posOf node) name
  attrs `seq` return (mkAttributedNode attrs)

-- convenient instance, the position of a list of things is the position of
-- the first thing in the list
--
instance Pos a => Pos [a] where
  posOf (x:_) = posOf x

emptyDeclr = CVarDeclr Nothing (newAttrsOnlyPos nopos)

-- extract all identifiers turned into `typedef-name's
--
isTypeDef :: [CDeclSpec] -> Bool
isTypeDef specs = (not . null) [()| CStorageSpec (CTypedef _) <- specs]

getTypeDefIdents :: [CDeclr] -> [Ident]
getTypeDefIdents declrs = catMaybes [declrToOptIdent declr | declr <- declrs]
  where
    declrToOptIdent :: CDeclr -> Maybe Ident
    declrToOptIdent (CVarDeclr optIde    _) = optIde
    declrToOptIdent (CPtrDeclr _ declr   _) = declrToOptIdent declr
    declrToOptIdent (CArrDeclr declr _   _) = declrToOptIdent declr
    declrToOptIdent (CFunDeclr declr _ _ _) = declrToOptIdent declr

happyError :: P a
happyError = parseError

parseC :: String -> Position -> PreCST s s' CHeader
parseC input initialPosition  = do
  nameSupply <- getNameSupply
  let ns = names nameSupply
  case execParser header input
                  initialPosition (map fst builtinTypeNames) ns of
    Left header -> return header
    Right (message, position) -> raiseFatal "Error in C header file."
                                            position message
}

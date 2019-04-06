(** Abstract syntax tree *)
open Core_kernel

open Stan_mir

(** Our type for identifiers, on which we record a location *)
type identifier =
  {name: string; id_loc: Mir.location_span sexp_opaque [@compare.ignore]}
[@@deriving sexp, hash, compare]

(** Arithmetic and logical operators *)
type operator =
  | Plus
  | PPlus
  | Minus
  | PMinus
  | Times
  | Divide
  | Modulo
  | LDivide
  | EltTimes
  | EltDivide
  | Pow
  | Or
  | And
  | Equals
  | NEquals
  | Less
  | Leq
  | Greater
  | Geq
  | PNot
  | Transpose
[@@deriving sexp, hash, compare]

(** Indices for array access *)
type 'e index =
  | All
  | Single of 'e
  | Upfrom of 'e
  | Downfrom of 'e
  | Between of 'e * 'e
[@@deriving sexp, hash, compare, map]

(** Expression shapes (used for both typed and untyped expressions, where we
    substitute untyped_expression or typed_expression for 'e *)
type 'e expression =
  | TernaryIf of 'e * 'e * 'e
  | BinOp of 'e * operator * 'e
  | PrefixOp of operator * 'e
  | PostfixOp of 'e * operator
  | Variable of identifier
  | IntNumeral of string
  | RealNumeral of string
  | FunApp of identifier * 'e list
  | CondDistApp of identifier * 'e list
  (* GetLP is deprecated *)
  | GetLP
  | GetTarget
  | ArrayExpr of 'e list
  | RowVectorExpr of 'e list
  | Paren of 'e
  | Indexed of 'e * 'e index list
[@@deriving sexp, hash, compare, map]

(** Untyped expressions, which have location_spans as meta-data *)
type untyped_expression =
  { expr_untyped: untyped_expression expression
  ; expr_untyped_loc: Mir.location_span sexp_opaque [@compare.ignore] }
[@@deriving sexp, compare, map, hash]

(** Typed expressions also have meta-data after type checking: a location_span, as well as a type
    and an origin block (lub of the origin blocks of the identifiers in it) *)
type typed_expression =
  { expr_typed: typed_expression expression
  ; expr_typed_loc: Mir.location_span sexp_opaque [@compare.ignore]
  ; expr_typed_ad_level: Mir.autodifftype
  ; expr_typed_type: Mir.unsizedtype }
[@@deriving sexp, compare, map, hash]

let expr_loc_lub exprs =
  match List.map ~f:(fun e -> e.expr_typed_loc) exprs with
  | [] -> raise_s [%message "Can't find location lub for empty list"]
  | [hd] -> hd
  | x1 :: tl -> List.fold ~init:x1 ~f:Mir.merge_spans tl

let expr_ad_lub exprs =
  exprs
  |> List.map ~f:(fun e -> e.expr_typed_ad_level)
  |> List.max_elt ~compare
  |> Option.value ~default:DataOnly

(* This directive silences some spurious warnings from ppx_deriving *)
[@@@ocaml.warning "-A"]

(** Assignment operators *)
type assignmentoperator =
  | Assign
  (* ArrowAssign is deprecated *)
  | ArrowAssign
  | OperatorAssign of operator
[@@deriving sexp, hash, compare]

(** Truncations *)
type 'e truncation =
  | NoTruncate
  | TruncateUpFrom of 'e
  | TruncateDownFrom of 'e
  | TruncateBetween of 'e * 'e
[@@deriving sexp, hash, compare, map]

(** Things that can be printed *)
type 'e printable = PString of string | PExpr of 'e
[@@deriving sexp, compare, map, hash]

(** Transformations (constraints) for global variable declarations *)
type 'e transformation =
  | Identity
  | Lower of 'e
  | Upper of 'e
  | LowerUpper of 'e * 'e
  | Offset of 'e
  | Multiplier of 'e
  | OffsetMultiplier of 'e * 'e
  | Ordered
  | PositiveOrdered
  | Simplex
  | UnitVector
  | CholeskyCorr
  | CholeskyCov
  | Correlation
  | Covariance
[@@deriving sexp, compare, map, hash]

(* let pp_transformation pp_e ppf = function
  | Identity -> ()
  | Lower expr -> (pp_e |> label "lower" |> angle_brackets) ppf expr
  | Upper expr -> (pp_e |> label "upper" |> angle_brackets) ppf expr
  | LowerUpper (lower_expr, upper_expr) ->
      ( Fmt.(pair ~sep:comma (pp_e |> label "lower") (pp_e |> label "upper"))
      |> angle_brackets )
        ppf (lower_expr, upper_expr)
  | Offset expr -> (pp_e |> label "offet" |> angle_brackets) ppf expr
  | Multiplier expr -> (pp_e |> label "multiplier" |> angle_brackets) ppf expr
  | OffsetMultiplier (offset_expr, mult_expr) ->
      ( Fmt.(
          pair ~sep:comma (pp_e |> label "offset") (pp_e |> label "multiplier"))
      |> angle_brackets )
        ppf (offset_expr, mult_expr)
  | Ordered -> (angle_brackets Fmt.string) ppf "ordered"
  | PositiveOrdered -> (angle_brackets Fmt.string) ppf "positive_ordered"
  | Simplex -> (angle_brackets Fmt.string) ppf "simplex"
  | UnitVector -> (angle_brackets Fmt.string) ppf "unit_vector"
  | CholeskyCorr -> (angle_brackets Fmt.string) ppf "cholesky_factor_corr"
  | CholeskyCov -> (angle_brackets Fmt.string) ppf "cholesky_factor_cov"
  | Correlation -> (angle_brackets Fmt.string) ppf "corr_matrix"
  | Covariance -> (angle_brackets Fmt.string) ppf "cov_matrix" *)

(** Statement shapes, where we substitute untyped_expression and untyped_statement
    for 'e and 's respectively to get untyped_statement and typed_expression and
    typed_statement to get typed_statement    *)
type ('e, 's) statement =
  | Assignment of
      { assign_identifier: identifier
      ; assign_indices: 'e index list
      ; assign_op: assignmentoperator
      ; assign_rhs: 'e }
  | NRFunApp of identifier * 'e list
  | TargetPE of 'e
  (* IncrementLogProb is deprecated *)
  | IncrementLogProb of 'e
  | Tilde of
      { arg: 'e
      ; distribution: identifier
      ; args: 'e list
      ; truncation: 'e truncation }
  | Break
  | Continue
  | Return of 'e
  | ReturnVoid
  | Print of 'e printable list
  | Reject of 'e printable list
  | Skip
  | IfThenElse of 'e * 's * 's option
  | While of 'e * 's
  | For of
      { loop_variable: identifier
      ; lower_bound: 'e
      ; upper_bound: 'e
      ; loop_body: 's }
  | ForEach of identifier * 'e * 's
  | Block of 's list
  | VarDecl of
      { sizedtype: 'e Mir.sizedtype
      ; transformation: 'e transformation
      ; identifier: identifier
      ; initial_value: 'e option
      ; is_global: bool }
  | FunDef of
      { returntype: Mir.returntype
      ; funname: identifier
      ; arguments: (Mir.autodifftype * Mir.unsizedtype * identifier) list
      ; body: 's }
[@@deriving sexp, hash, compare, map]

(** Statement return types which we will decorate statements with during type
    checking: the purpose is to check that function bodies have the correct
    return type in every possible execution branch.
    NoReturnType corresponds to not having a return statement in it.
    Incomplete rt corresponds to having some return statement(s) of type rt
    in it, but not one in every branch
    Complete rt corresponds to having a return statement of type rt in every branch
    AnyReturnType corresponds to statements which have an error in every branch  *)
type statement_returntype =
  | NoReturnType
  | Incomplete of Mir.returntype
  | Complete of Mir.returntype
  | AnyReturnType
[@@deriving sexp, hash, compare]

(** Untyped statements, which have location_spans as meta-data *)
type untyped_statement =
  { stmt_untyped: (untyped_expression, untyped_statement) statement
  ; stmt_untyped_loc: Mir.location_span sexp_opaque [@compare.ignore] }
[@@deriving sexp, compare, map, hash]

(** Typed statements also have meta-data after type checking: a location_span, as well as a statement returntype
    to check that function bodies have the right return type*)
type typed_statement =
  { stmt_typed: (typed_expression, typed_statement) statement
  ; stmt_typed_loc: Mir.location_span sexp_opaque [@compare.ignore]
  ; stmt_typed_returntype: statement_returntype }
[@@deriving sexp, compare, map, hash]

(** Program shapes, where we obtain types of programs if we substitute typed or untyped
    statements for 's *)
type 's program =
  { functionblock: 's list option
  ; datablock: 's list option
  ; transformeddatablock: 's list option
  ; parametersblock: 's list option
  ; transformedparametersblock: 's list option
  ; modelblock: 's list option
  ; generatedquantitiesblock: 's list option }
[@@deriving sexp, hash, compare, map]

(** Untyped programs (before type checking) *)
type untyped_program = untyped_statement program
[@@deriving sexp, compare, map]

(** Typed programs (after type checking) *)
type typed_program = typed_statement program [@@deriving sexp, compare, map]

(** Forgetful function from typed to untyped expressions *)
let rec untyped_expression_of_typed_expression {expr_typed; expr_typed_loc; _}
    =
  { expr_untyped=
      map_expression untyped_expression_of_typed_expression expr_typed
  ; expr_untyped_loc= expr_typed_loc }

(** Forgetful function from typed to untyped statements *)
let rec untyped_statement_of_typed_statement {stmt_typed; stmt_typed_loc; _} =
  { stmt_untyped=
      map_statement untyped_expression_of_typed_expression
        untyped_statement_of_typed_statement stmt_typed
  ; stmt_untyped_loc= stmt_typed_loc }

(** Forgetful function from typed to untyped programs *)
let untyped_program_of_typed_program =
  map_program untyped_statement_of_typed_statement

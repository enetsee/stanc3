open Mir
open Core_kernel

let rec trans_expr {Ast.expr_typed; _} =
  match expr_typed with
  | Ast.TernaryIf (cond, ifb, elseb) ->
      TernaryIf (trans_expr cond, trans_expr ifb, trans_expr elseb)
  | Ast.BinOp (lhs, op, rhs) -> BinOp (trans_expr lhs, op, trans_expr rhs)
  | Ast.PrefixOp (op, e) | Ast.PostfixOp (e, op) ->
      FnApp (Operators.operator_name op, [trans_expr e])
  | Ast.Variable {name; _} -> Var name
  | Ast.IntNumeral x -> Lit (Int, x)
  | Ast.RealNumeral x -> Lit (Real, x)
  | Ast.FunApp ({name; _}, args) | Ast.CondDistApp ({name; _}, args) ->
      FnApp (name, List.map ~f:trans_expr args)
  | Ast.GetLP | Ast.GetTarget -> Var "target"
  | Ast.ArrayExpr eles -> FnApp ("make_array", List.map ~f:trans_expr eles)
  | Ast.RowVectorExpr eles -> FnApp ("make_rowvec", List.map ~f:trans_expr eles)
  | Ast.Paren x -> trans_expr x
  | Ast.Indexed (lhs, indices) ->
      Indexed (trans_expr lhs, List.map ~f:trans_idx indices)

and trans_idx = function
  | Ast.All -> All
  | Ast.Upfrom e -> Upfrom (trans_expr e)
  | Ast.Downfrom e -> Downfrom (trans_expr e)
  | Ast.Between (lb, ub) -> Between (trans_expr lb, trans_expr ub)
  | Ast.Single e -> (
    match e.expr_typed_type with
    | Ast.UInt -> Single (trans_expr e)
    | Ast.UArray _ -> MultiIndex (trans_expr e)
    | _ ->
        raise_s
          [%message
            "Expecting int or array" (e.expr_typed_type : Ast.unsizedtype)] )

let trans_sizedtype = Ast.map_sizedtype trans_expr
let neg_inf = FnApp ("negative_infinity", [])

let targetpe e =
  let t = Var "target" in
  Assignment (t, BinOp (t, Plus, e))

let trans_loc = function
  | Ast.Nowhere -> ""
  | Ast.Location (start, end_) ->
      (* XXX hack *)
      let open Lexing in
      sprintf "\"%s\", line %d-%d" start.pos_fname start.pos_lnum end_.pos_lnum

let bind_loc loc s = {stmt= s; sloc= trans_loc loc}
let no_loc = ""
let with_no_loc s = {stmt= s; sloc= no_loc}
let trans_trans = Ast.map_transformation trans_expr
let trans_arg (adtype, ut, ident) = (adtype, ident.Ast.name, ut)

let truncate_dist ast_obs t =
  let add_inf = targetpe neg_inf and obs = trans_expr ast_obs in
  let trunc cond x y =
    bind_loc x.Ast.expr_typed_loc
      (IfElse
         (BinOp (obs, cond, trans_expr x), bind_loc x.expr_typed_loc add_inf, y))
  in
  match t with
  | Ast.NoTruncate -> None
  | Ast.TruncateUpFrom lb -> Some (trunc Less lb None)
  | Ast.TruncateDownFrom ub -> Some (trunc Greater ub None)
  | Ast.TruncateBetween (lb, ub) ->
      Some (trunc Less lb (Some (trunc Greater ub None)))

let rec trans_stmt {Ast.stmt_typed; stmt_typed_loc; _} =
  let or_skip = Option.value ~default:Skip in
  let s =
    match stmt_typed with
    | Ast.Assignment {assign_indices; assign_rhs; assign_identifier; assign_op}
      ->
        let assignee = Var assign_identifier.name in
        let assignee =
          match assign_indices with
          | [] -> assignee
          | lst -> Indexed (assignee, List.map ~f:trans_idx lst)
        and rhs = trans_expr assign_rhs in
        let rhs =
          match assign_op with
          | Ast.Assign | Ast.ArrowAssign -> rhs
          | Ast.OperatorAssign op ->
              FnApp (Operators.operator_name op, [assignee; rhs])
        in
        Assignment (assignee, rhs)
    | Ast.NRFunApp ({name; _}, args) ->
        NRFnApp (name, List.map ~f:trans_expr args)
    | Ast.IncrementLogProb e | Ast.TargetPE e -> targetpe (trans_expr e)
    | Ast.Tilde {arg; distribution; args; truncation} ->
        let add_dist =
          (* XXX distribution name suffix? *)
          (* XXX Reminder to differentiate between tilde, which drops constants, and
             vanilla target +=, which doesn't. Can use _unnormalized or something.*)
          targetpe
            (FnApp (distribution.name, List.map ~f:trans_expr (arg :: args)))
        in
        Block
          [ Option.value
              ~default:(bind_loc stmt_typed_loc Skip)
              (truncate_dist arg truncation)
          ; bind_loc stmt_typed_loc add_dist ]
    | Ast.Print ps -> NRFnApp ("print", List.map ~f:trans_printable ps)
    | Ast.Reject ps -> NRFnApp ("reject", List.map ~f:trans_printable ps)
    | Ast.IfThenElse (cond, ifb, elseb) ->
        IfElse (trans_expr cond, trans_stmt ifb, Option.map ~f:trans_stmt elseb)
    | Ast.While (cond, body) -> While (trans_expr cond, trans_stmt body)
    | Ast.For {loop_variable; lower_bound; upper_bound; loop_body} ->
        For
          { loopvar= Var loop_variable.Ast.name
          ; lower= trans_expr lower_bound
          ; upper= trans_expr upper_bound
          ; body= trans_stmt loop_body }
    | Ast.ForEach (loopvar, iteratee, body) ->
        For
          { loopvar= Var loopvar.Ast.name
          ; lower= Lit (Int, "0")
          ; upper= FnApp ("length", [trans_expr iteratee])
          ; body= trans_stmt body }
    | Ast.FunDef {returntype; funname; arguments; body} ->
        FunDef
          { returntype=
              ( match returntype with
              | Ast.Void -> None
              | ReturnType ut -> Some ut )
          ; name= funname.name
          ; arguments= List.map ~f:trans_arg arguments
          ; body= trans_stmt body }
    | Ast.VarDecl {sizedtype; transformation; identifier; initial_value; _} ->
        let name = identifier.name in
        (* XXX Deal with global vs unglobal *)
        (* XXX Should also generate the statements that will read the data in
           and validate it... Then a CSE pass will automatically fulfill one of our
           Stanc3 promises to do data checking only once and at the appropriate level
        *)
        SList
          (List.map ~f:(bind_loc stmt_typed_loc)
             [ Decl
                 { adtype= AutoDiffable
                 ; vident= name
                 ; st= trans_sizedtype sizedtype
                 ; trans= trans_trans transformation }
             ; Option.map
                 ~f:(fun x -> Assignment (Var name, trans_expr x))
                 initial_value
               |> or_skip ])
    | Ast.Block stmts -> Block (List.map ~f:trans_stmt stmts)
    | Ast.Return e -> Return (Some (trans_expr e))
    | Ast.ReturnVoid -> Return None
    | Ast.Break -> Break
    | Ast.Continue -> Continue
    | Ast.Skip -> Skip
  in
  bind_loc stmt_typed_loc s

and trans_printable (p : Ast.typed_expression Ast.printable) =
  match p with Ast.PString s -> Lit (Str, s) | Ast.PExpr e -> trans_expr e

(* XXX Write a function that generates MIR to execute once on each thing in some nested
   arrays (but not elements within a matrix or vector) *)

(*
let mir_for_each_in_array (st : sizedtype) (s : expr -> stmt_loc) =
  match st with
  | SInt -> s
  | SReal -> ( ?? )
  | SArray (_, _) -> ( ?? )
  | SVector _ -> ( ?? )
  | SRowVector _ -> ( ?? )
  | SMatrix _ -> ( ?? )
*)
let rec trans_checks cvarname ctype t =
  let check = {cvarname; ctype; cargs= []; cfname= ""} in
  match t with
  | Ast.Identity -> []
  | Ast.Lower lb -> [Check {check with cargs= [lb]; cfname= "greater_or_equal"}]
  | Ast.Upper ub -> [Check {check with cargs= [ub]; cfname= "less_or_equal"}]
  | Ast.LowerUpper (lb, ub) ->
      [Ast.Lower lb; Upper ub]
      |> List.map ~f:(trans_checks cvarname ctype)
      |> List.concat
  | Ast.OffsetMultiplier (_, _) ->
      raise_s
        [%message
          "offset multiplier not yet implemented in the Stan Math library"]
  | Ast.Ordered -> [Check {check with cfname= "ordered"}]
  | Ast.PositiveOrdered -> [Check {check with cfname= "positive_ordered"}]
  | Ast.Simplex -> [Check {check with cfname= "simplex"}]
  | Ast.UnitVector -> [Check {check with cfname= "unit_vector"}]
  | Ast.CholeskyCorr -> [Check {check with cfname= "cholesky_factor_corr"}]
  | Ast.CholeskyCov -> [Check {check with cfname= "cholesky_factor"}]
  | Ast.Correlation -> [Check {check with cfname= "corr_matrix"}]
  | Ast.Covariance -> [Check {check with cfname= "cov_matrix"}]

(** Adds Mir statements that validate and read in the variable*)
let add_data_read_field {stmt; sloc} =
  let with_sloc stmt = {sloc; stmt} in
  match stmt with
  | Decl {vident; trans; st; _} ->
      let check_stmts = List.map ~f:with_sloc (trans_checks vident st trans) in
      with_sloc (SList (with_sloc stmt :: check_stmts))
  | _ -> with_sloc stmt

(* XXX To add validation logic to MIR
   We can add validate_non_negative_index, context__.validate_dims,
*)

let trans_prog filename
    { Ast.functionblock
    ; datablock
    ; transformeddatablock
    ; parametersblock
    ; transformedparametersblock
    ; modelblock
    ; generatedquantitiesblock } =
  let trans_or_skip lst_option =
    with_no_loc
      ( match lst_option with
      | None | Some [] -> Skip
      | Some lst -> SList (List.map ~f:trans_stmt lst) )
  in
  let lbind s = match s.stmt with SList ls -> ls | Skip -> [] | _ -> [s] in
  let coalesce stmts =
    let flattened = List.(concat (map ~f:lbind stmts)) in
    with_no_loc (match flattened with [] -> Skip | _ :: _ -> SList flattened)
  in
  (* XXX probably a weird place to keep the name*)
  { prog_name= !Semantic_check.model_name
  ; prog_path= filename
  ; functionsb= trans_or_skip functionblock
  ; datab=
      coalesce
        [ datablock |> trans_or_skip |> add_data_read_field
          (* |> add_check_constraints *)
        ; transformeddatablock |> trans_or_skip ]
  ; paramsb= trans_or_skip parametersblock
  ; modelb=
      coalesce
        (* XXX save transformed parameters *)
        (List.map ~f:trans_or_skip [transformedparametersblock; modelblock])
  ; gqb= trans_or_skip generatedquantitiesblock }

(* Code for optimization passes on the MIR *)

val function_inlining : Mir.stmt_loc Mir.prog -> Mir.stmt_loc Mir.prog
val loop_unrolling : Mir.stmt_loc Mir.prog -> Mir.stmt_loc Mir.prog

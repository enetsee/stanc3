  $ $TESTDIR/..//../../_build/default/stanc.exe "$TESTDIR/..//new/lexing_error.stan"
  Uncaught exception:
    
    (Failure "lexing: empty token")
  
  Raised by primitive operation at file "lexing.ml", line 65, characters 15-37
  Called from file "lib/lexer.ml", line 4758, characters 8-65
  Called from file "Engine.ml", line 477, characters 18-30
  Called from file "Engine.ml", line 534, characters 21-27
  Called from file "lib/Parse.ml", line 52, characters 4-87
  Called from file "lib/Parse.ml", line 66, characters 6-28
  Called from file "stanc.ml", line 46, characters 13-62
  Called from file "list.ml", line 88, characters 20-23
  Called from file "stanc.ml", line 66, characters 12-36
  Called from file "stanc.ml", line 72, characters 8-15
  [2]

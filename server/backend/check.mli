val set_ocaml_switches : Server_workdirs.t -> Intf.Compiler.t list -> unit Lwt.t
val run :
  on_finished:(Server_workdirs.t -> unit) ->
  Server_workdirs.t ->
  unit Lwt.t

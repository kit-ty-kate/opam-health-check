open Lwt.Infix

let parse_key key =
  let key = IO.with_in (Fpath.to_string key) (IO.read_all ?size:None) in
  let key = Nocrypto.Rsa.priv_of_sexp (Sexplib.Sexp.of_string key) in
  Nocrypto.Rsa.pub_of_priv key

let partial_encrypt key msg =
  Cstruct.to_string (Nocrypto.Rsa.encrypt ~key (Cstruct.of_string msg))

let rec encrypt_msg ~key msg =
  let max_size = Nocrypto.Rsa.pub_bits key / 8 in
  if String.length msg <= max_size then
    partial_encrypt key msg
  else
    let msg, next = String.take_drop max_size msg in
    partial_encrypt key msg ^ encrypt_msg ~key next

let print_body body =
  let stream = Cohttp_lwt.Body.to_stream body in
  Lwt_stream.iter (fun s -> print_string s; flush stdout) stream >|= fun () ->
  print_newline ()

let process_response (res, body) =
  match Cohttp.Response.status res with
  | `OK ->
      print_body body
  | `Upgrade_required ->
      print_body body >|= fun () ->
      raise Exit
  | _ ->
      print_endline "A problem occured";
      raise Exit

let send_msg ~profilename ~confdir ~conffile msg =
  let conf = Configfile.from_file ~confdir conffile in
  let conf = Configfile.profile ~profilename conf in
  let hostname = Configfile.hostname conf in
  let port = Configfile.port conf in
  let username = Configfile.username conf in
  let keyfile = Configfile.keyfile conf in
  let key = parse_key keyfile in
  let prefix = username^"\n" in
  let msg = String.concat "\n" msg in
  let msg = encrypt_msg ~key (prefix^msg) in
  let uri = Uri.make ~scheme:"http" ~host:hostname ~port () in
  let prefix = Oca_lib.protocol_version^"\n"^prefix in
  print_endline "Sending command...";
  Lwt_main.run begin
    Cohttp_lwt_unix.Client.post ~body:(`String (prefix^msg)) uri >>=
    process_response
  end

let set_auto_run_interval ~confdir ~conffile profilename i =
  send_msg ~profilename ~confdir ~conffile ["set-auto-run-interval"; i]

let set_auto_run_interval_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (set_auto_run_interval ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt string "default" & info ~docv:"PROFILENAME" ["profile"; "p"]) $
    Cmdliner.Arg.(required & pos 0 (some string) None & info ~docv:"HOURS" [])
  in
  let info = Cmdliner.Term.info "set-auto-run-interval" in
  (term, info)

let set_ocaml_switches ~confdir ~conffile profilename switches =
  send_msg ~profilename ~confdir ~conffile ("set-ocaml-switches"::switches)

let set_ocaml_switches_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (set_ocaml_switches ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt string "default" & info ~docv:"PROFILENAME" ["profile"; "p"]) $
    Cmdliner.Arg.(value & pos_all string [] & info ~docv:"SWITCHES" [])
  in
  let info = Cmdliner.Term.info "set-ocaml-switches" in
  (term, info)

let set_list_command ~confdir ~conffile profilename cmd =
  send_msg ~profilename ~confdir ~conffile ["set-list-command";cmd]

let set_list_command_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (set_list_command ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt string "default" & info ~docv:"PROFILENAME" ["profile"; "p"]) $
    Cmdliner.Arg.(required & pos 0 (some string) None & info ~docv:"CMD" [])
  in
  let info = Cmdliner.Term.info "set-list-command" in
  (term, info)

let run ~confdir ~conffile profilename () =
  (* TODO: Catch the exception if the config file doesn't exist *)
  send_msg ~profilename ~confdir ~conffile ["run"]

let run_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (run ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt string "default" & info ~docv:"PROFILENAME" ["profile"; "p"]) $
    Cmdliner.Term.const ()
  in
  let info = Cmdliner.Term.info "run" in
  (term, info)

let retry ~confdir ~conffile profilename () =
  send_msg ~profilename ~confdir ~conffile ["retry"]

let retry_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (retry ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt string "default" & info ~docv:"PROFILENAME" ["profile"; "p"]) $
    Cmdliner.Term.const ()
  in
  let info = Cmdliner.Term.info "retry" in
  (term, info)

let add_user ~confdir ~conffile profilename username =
  send_msg ~profilename ~confdir ~conffile ["add-user";username]

let add_user_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (add_user ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt string "default" & info ~docv:"PROFILENAME" ["profile"; "p"]) $
    Cmdliner.Arg.(required & pos 0 (some string) None & info ~docv:"USERNAME" [])
  in
  let info = Cmdliner.Term.info "add-user" in
  (term, info)

let init ~confdir ~conffile = function
  | Some local_workdir ->
      let local_workdir = Server_workdirs.create ~workdir:local_workdir in
      let server_conf = Server_configfile.from_workdir local_workdir in
      let hostname = Oca_lib.localhost in
      let port = Server_configfile.admin_port server_conf in
      let username = Oca_lib.default_admin_name in
      let keyfile = Server_workdirs.keyfile ~username local_workdir in
      Configfile.init_with_values ~confdir ~hostname ~port ~username ~keyfile conffile
  | None ->
      Configfile.init ~confdir conffile

let init_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (init ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt (some dir) None & info ["from-local-workdir"])
  in
  let info = Cmdliner.Term.info "init" in
  (term, info)

let clear_cache ~confdir ~conffile profilename () =
  send_msg ~profilename ~confdir ~conffile ["clear-cache"]

let clear_cache_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (clear_cache ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt string "default" & info ~docv:"PROFILENAME" ["profile"; "p"]) $
    Cmdliner.Term.const ()
  in
  let info = Cmdliner.Term.info "clear-cache" in
  (term, info)

let log ~confdir ~conffile profilename () =
  send_msg ~profilename ~confdir ~conffile ["log"]

let log_cmd ~confdir ~conffile =
  let term =
    let ($) = Cmdliner.Term.($) in
    Cmdliner.Term.const (log ~confdir ~conffile) $
    Cmdliner.Arg.(value & opt string "default" & info ~docv:"PROFILENAME" ["profile"; "p"]) $
    Cmdliner.Term.const ()
  in
  let info = Cmdliner.Term.info "log" in
  (term, info)

let cmds =
  let confdir = XDGBaseDir.(default.config_home) in
  let confdir = Fpath.v confdir in
  let confdir = Fpath.add_seg confdir "opam-check-all" in
  let conffile = Fpath.add_seg confdir "config.yaml" in
  [
    init_cmd ~confdir ~conffile; (* TODO: Handle profilename on init *)
    add_user_cmd ~confdir ~conffile;
    set_ocaml_switches_cmd ~confdir ~conffile;
    set_list_command_cmd ~confdir ~conffile;
    run_cmd ~confdir ~conffile;
    retry_cmd ~confdir ~conffile;
    clear_cache_cmd ~confdir ~conffile;
    log_cmd ~confdir ~conffile;
  ]

let () =
  let term = Cmdliner.Term.const () in
  let info =
    Cmdliner.Term.info
      ~version:Config.version
      Config.name
  in
  let eval = Cmdliner.Term.eval_choice ~catch:false in
  try Cmdliner.Term.exit (eval (term, info) cmds) with
  | Exit -> exit 1

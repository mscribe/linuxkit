open Lwt.Infix
open Sdk
open Astring

let src = Logs.Src.create "dhcp-client" ~doc:"DHCP client"
module Log = (val Logs.src_log src : Logs.LOG)

module Handlers = struct

  (* System handlers *)

  let contents_of_diff = function
    | `Added (_, `Contents (v, _))
    | `Updated (_, (_, `Contents (v, _))) -> Some v
    | _ -> None

  let with_ip str f =
    match Ipaddr.V4.of_string (String.trim str) with
    | Some ip ->
      Log.info (fun l -> l "SET IP to %a" Ipaddr.V4.pp_hum ip);
      f ip
    | None ->
      Log.err (fun l -> l "%s is not a valid IP" str);
      Lwt.return_unit

  let ip ~ethif t =
    Ctl.KV.watch_key t ["ip"] (fun diff ->
        match contents_of_diff diff with
        | None    -> Lwt.return_unit
        | Some ip -> with_ip ip (fun ip -> Net.set_ip ethif ip)
      )

  let gateway t =
    Ctl.KV.watch_key t ["gateway"] (fun diff ->
        match contents_of_diff diff with
        | None    -> Lwt.return_unit
        | Some gw -> with_ip gw (fun gw -> Net.set_gateway gw)
      )

  let handlers ~ethif = [
    ip ~ethif;
    gateway;
  ]

  let watch ~ethif db =
    Lwt_list.map_p (fun f -> f db) (handlers ~ethif) >>= fun _ ->
    let t, _ = Lwt.task () in
    t

end

external dhcp_filter: unit -> string = "bpf_filter"

let t = Init.Pipe.v ()

(*
let default_cmd = [
  "/calf/dhcp-client-calf"; "--net=3"; "--ctl=4"; "-vv";
]
*)

let default_cmd = [
  "/usr/bin/runc"; "run"; "--preserve-fds"; "2"; "--bundle"; "calf";  "calf"
]

let read_cmd file =
  if Sys.file_exists file then
    let ic = open_in_bin file in
    let line = input_line ic in
    String.cuts ~sep:" " line
  else
    failwith ("Cannot read " ^ file)

let infof fmt =
  Fmt.kstrf (fun msg () ->
      let date = Int64.of_float (Unix.gettimeofday ()) in
      Irmin.Info.v ~date ~author:"priv" msg
    ) fmt

let run () cmd ethif path =
  let cmd = match cmd with
    | None   -> default_cmd
    | Some f -> read_cmd f
  in
  Lwt_main.run (
    Lwt_switch.with_switch @@ fun switch ->
    let routes = [
      ["ip"]     , [`Write];
      ["mac"]    , [`Read ];
      ["gateway"], [`Write];
    ] in
    Ctl.v path >>= fun db ->
    let ctl fd =
      let service = Ctl.Server.service ~routes db in
      let endpoint = Capnp_rpc_lwt.Endpoint.of_flow ~switch (module Sdk.IO) fd in
      ignore (Capnp_rpc_lwt.CapTP.of_endpoint ~switch ~offer:service endpoint)
    in
    let handlers () = Handlers.watch ~ethif db in
    let net = Init.rawlink ~filter:(dhcp_filter ()) ethif in
    Net.mac ethif >>= fun mac ->
    let mac = Macaddr.to_string mac ^ "\n" in
    Ctl.KV.set db ~info:(infof "Add mac") ["mac"] mac >>= fun () ->
    Init.run t ~net ~ctl ~handlers cmd
  )

(* CLI *)

open Cmdliner

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  let pp_header ppf x =
    Fmt.pf ppf "%5d: %a " (Unix.getpid ()) Logs_fmt.pp_header x
  in
  Logs.set_reporter (Logs_fmt.reporter ~pp_header ());
  ()

let setup_log =
  Term.(const setup_log $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let cmd =
  let doc =
    Arg.info ~docv:"CMD" ~doc:"Command to run the calf process." ["cmd"]
  in
  Arg.(value & opt (some string) None & doc)

let ethif =
  let doc =
    Arg.info ~docv:"NAME" ~doc:"The interface to listen too." ["ethif"]
  in
  Arg.(value & opt string "eth0" & doc)

let path =
  let doc =
    Arg.info ~docv:"DIR"
      ~doc:"The directory where control state will be stored." ["path"]
  in
  Arg.(value & opt string "/data" & doc)

let run =
  Term.(const run $ setup_log $ cmd $ ethif $ path),
  Term.info "dhcp-client" ~version:"0.0"

let () = match Term.eval run with
  | `Error _ -> exit 1
  | `Ok () |`Help |`Version -> exit 0

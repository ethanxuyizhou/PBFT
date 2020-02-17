open Core
open Async

let run_server ~ports ~me =
  let args =
    let port_args =
      List.bind ports ~f:(fun port -> [ "-port"; string_of_int port ])
    in
    let me_arg = [ "-me"; string_of_int me ] in
    me_arg @ port_args
  in
  let open Deferred.Or_error.Let_syntax in
  let%map _result = Process.run ~prog:"{PBFT_SERVER_DIR}/server.exe" ~args () in
  ()

let run_servers ~ports =
  Deferred.Or_error.List.iteri ports ~f:(fun i _port -> run_server ~ports ~me:i)

let run_client ~name ~server_host_and_ports =
  let args =
    let name_args = [ "-name"; name ] in
    let host_and_port_args =
      List.bind server_host_and_ports ~f:(fun host_and_port ->
          [ "-host-and-port"; host_and_port ])
    in
    [ "-test" ] @ name_args @ host_and_port_args
  in
  let open Deferred.Or_error.Let_syntax in
  let%map _result = Process.run ~prog:"{PBFT_CLIENT_DIR}/client.exe" ~args () in
  ()

let test1 =
  (* Basic test setting *)
  run_servers ~ports:[ 5000; 6000; 7000; 8000 ]

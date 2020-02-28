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
    [ "-TEST" ] @ name_args @ host_and_port_args
  in
  let open Deferred.Or_error.Let_syntax in
  let%map _result = Process.run ~prog:"{PBFT_CLIENT_DIR}/client.exe" ~args () in
  ()

let rec send_message port =
  match%bind Rpc.Connection.client (Tcp.where_to_connect port) with
  | `Eof ->
      let%bind () = after Time.Span.second in
      establish_connection_with_client port
  | `Ok connection -> connection

let%expect_test _ =
  let server_ports = [ 5000; 6000; 7000; 8000 ] in
  let server_host_and_ports = List.map ports ~f:(sprintf "localhost:%s") in
  let server_addresses =
    List.map server_host_and_ports
      ~f:(Tcp.Where_to_connect.of_host_and_port Host_and_port.of_string)
  in
  let%bind () = run_servers ~ports:server_ports in
  let%bind () = run_client ~name:"1" ~server_host_and_ports in
  let client_port = int_of_string (Unix.getenv_exn "PBFT_TEST_CLIENT_PORT") in
  let rws =
    List.map server_addresses ~f:(fun address ->
        let r, w = Pipe.create () in
        (r, w, address))
  in
  let writes = List.map rws ~f:(fun (_r, _w, address) -> address) in
  don't_wait_for
    (Deferred.List.iter rws ~f:(fun (r, _w, address) ->
         transfer_message_from_pipe_to_address r));
  let%bind connection = establish_connection_with_client port in
  ()

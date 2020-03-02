open Core
open Async

let run_server ~ports ~me ~finished =
  let args =
    let port_args =
      List.bind ports ~f:(fun port ->
          [ "-host-and-port"; sprintf "localhost:%d" port ])
    in
    let me_arg = [ "-me"; string_of_int me ] in
    me_arg @ port_args
  in
  let%map process =
    Process.create_exn
      ~prog:
        "/Users/ethan/Desktop/project/ocaml/_build/default/PBFT/pbft/src/server/server.exe"
      ~args ()
  in
  upon finished (fun _ ->
      Signal.send_i Signal.kill (`Pid (Process.pid process)));
  ()

let run_servers ~ports ~finished =
  Deferred.List.iteri ~how:`Parallel ports ~f:(fun i _port ->
      run_server ~ports ~me:i ~finished)

let run_client ~name ~server_host_and_ports ~port ~finished =
  let args =
    let name_args = [ "-name"; name ] in
    let host_and_port_args =
      List.bind server_host_and_ports ~f:(fun host_and_port ->
          [ "-host-and-port"; host_and_port ])
    in
    [ "-TEST" ] @ name_args @ host_and_port_args
  in
  let%map process =
    Process.create_exn
      ~env:(`Replace [ ("PBFT_TEST_CLIENT_PORT", string_of_int port) ])
      ~prog:
        "/Users/ethan/Desktop/project/ocaml/_build/default/PBFT/pbft/src/client/client.exe"
      ~args ()
  in
  upon finished (fun _ ->
      Signal.send_i Signal.kill (`Pid (Process.pid process)));
  ()

let setup ~server_ports ~client_port ~r ~finished =
  let%bind () = run_servers ~ports:server_ports ~finished in
  let server_host_and_ports =
    List.map server_ports ~f:(sprintf "localhost:%d")
  in
  let%map () =
    run_client ~name:"1" ~server_host_and_ports ~port:client_port ~finished
  in
  let address =
    Tcp.Where_to_connect.of_host_and_port
      (Host_and_port.of_string (sprintf "localhost:%d" client_port))
  in
  don't_wait_for (Common.transfer_message_from_pipe_to_address r address)

let%expect_test _ =
  let finished_ivar = ref (Ivar.create ()) in
  let finished = Deferred.create (fun i -> finished_ivar := i) in
  let server_ports = [ 5000; 6000; 7000; 8000 ] in
  let client_port = 3000 in
  let r, w = Pipe.create () in
  let%bind () = setup ~server_ports ~client_port ~r ~finished in
  let address =
    Tcp.Where_to_connect.of_host_and_port
      (Host_and_port.of_string (sprintf "localhost:%d" client_port))
  in
  let data_r =
    let r, w = Pipe.create () in
    don't_wait_for
      (Common.ping_for_message_stream w
         (fun connection ->
           Rpc.Pipe_rpc.dispatch Rpcs.App_to_client_rpcs.data_rpc connection ())
         address);
    r
  in
  let%bind () = after Time.Span.second in
  let%bind () =
    Pipe.write w (fun connection ->
        Deferred.return
          (Rpc.One_way.dispatch Rpcs.App_to_client_rpcs.operation_rpc connection
             (Rpcs.Interface.Operation.Add 1)))
  in
  let%bind () =
    match%map Pipe.read data_r with `Eof -> printf "" | `Ok x -> printf "%d" x
  in
  let%map () = [%expect {| 1 |}] in
  Ivar.fill !finished_ivar ()

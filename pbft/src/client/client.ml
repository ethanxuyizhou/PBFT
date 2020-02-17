open Core
open Async
open Rpcs

let operation_r, operation_w = Pipe.create ()

let data_r, data_w = Pipe.create ()

let operation_implementation =
  Rpc.One_way.implement App_to_client_rpcs.operation_rpc (fun _state query ->
      Pipe.write_without_pushback operation_w query)

let data_implementation =
  Rpc.Pipe_rpc.implement App_to_client_rpcs.data_rpc (fun _state _query ->
      let r, w = Pipe.create () in
      don't_wait_for (Pipe.transfer data_r w ~f:Fn.id);
      Deferred.return (Result.return r))

let implementations =
  Rpc.Implementations.create_exn
    ~implementations:[ operation_implementation; data_implementation ]
    ~on_unknown_rpc:`Close_connection

let send_update ~addresses query =
  let send_update_to_address address =
    match%bind Rpc.Connection.client address with
    | Error _ -> Deferred.unit
    | Ok connection ->
        let (_ : unit Or_error.t) =
          Rpc.One_way.dispatch Client_to_server_rpcs.request_rpc connection
            query
        in
        Rpc.Connection.close connection
  in
  let key =
    Record_manager.Key.create (Client_to_server_rpcs.Request.timestamp query)
  in
  match%bind Record_manager.has_received_reply key with
  | false -> Deferred.List.iter addresses ~f:send_update_to_address
  | true -> Deferred.unit

 = Response.replica_number response in
      let data = Response.result response in
      let key = Record_manager.Key.create timestamp in
      let%bind () = Record_manager.update key ~data ~replica_number in
      let%bind size = Record_manager.size key ~data in
      if size = f + 1 then Pipe.write data_w data else Deferred.unit)

let command =
  Command.async ~summary:""
    (let open Command.Let_syntax in
    let%map_open host_and_ports =
      flag "-host-and-port" (listed host_and_port) ~doc:""
    and name = flag "-name" (required string) ~doc:"" in
    fun () ->
      let open Deferred.Let_syntax in
      let open Async_rpc_kernel in
      let f = (List.length host_and_ports - 1) / 3 in
      let addresses =
        List.map host_and_ports ~f:Tcp.Where_to_connect.of_host_and_port
      in
      don't_wait_for (main_loop f addresses name);
      don't_wait_for
        (Pipe.iter operation_r ~f:(fun operation' ->
             let request =
               Client_to_server_rpcs.Request.
                 {
                   operation = operation';
                   timestamp = Time.now ();
                   name_of_client = name;
                 }
             in
             send_update ~addresses request));
      let%bind _ =
        Tcp.Server.create ~on_handler_error:`Ignore
          (Tcp.Where_to_listen.of_port 80) (fun _ reader writer ->
            printf "connected\n";
            let app_to_ws, ws_write = Pipe.create () in
            let ws_read, ws_to_app = Pipe.create () in
            don't_wait_for
              (let%bind _ =
                 Websocket_async.server ~reader ~writer ~app_to_ws ~ws_to_app ()
               in
               Deferred.unit);
            let pipe_r, pipe_w =
              let r1, w1 = Pipe.create () in
              let r2, w2 = Pipe.create () in
              don't_wait_for
                (Pipe.transfer ws_read w1
                   ~f:(fun Websocket.Frame.{ opcode; extension; final; content }
                           ->
                     ignore (opcode : Websocket.Frame.Opcode.t);
                     ignore (extension : int);
                     ignore (final : bool);
                     content));
              don't_wait_for
                (Pipe.iter r2 ~f:(fun content ->
                     Pipe.write ws_write
                       (Websocket.Frame.create
                          ~opcode:Websocket.Frame.Opcode.Binary ~content ())));
              (r1, w2)
            in
            let transport =
              Pipe_transport.create Pipe_transport.Kind.string pipe_r pipe_w
            in
            Rpc.Connection.server_with_close transport ~implementations
              ~connection_state:(fun _ -> ())
              ~on_handshake_error:`Ignore)
      in
      Deferred.never ())

let () = Command.run command

open Core
open Async
open Rpcs

let data = ref (Interface.Data.init ())

type request =
  | Client of Client_to_server_rpcs.Request.t
  | Preprepare of Server_preprepare_rpcs.Request.t
  | Prepare of Server_prepare_rpcs.Request.t
  | Commit of Server_commit_rpcs.Request.t

let request_reader, request_writer = Pipe.create ()

let client_request_implementation =
  Rpc.One_way.implement Client_to_server_rpcs.request_rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Client query)))

let client_response_implementation =
  Rpc.Pipe_rpc.implement Client_to_server_rpcs.response_rpc
    Client_connection_manager.establish_communication

let preprepare_implementation =
  Rpc.One_way.implement Server_preprepare_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Preprepare query)))

let prepare_implementation =
  Rpc.One_way.implement Server_prepare_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Prepare query)))

let commit_implementation =
  Rpc.One_way.implement Server_commit_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Commit query)))

let implementations =
  let implementations =
    [
      client_request_implementation;
      client_response_implementation;
      preprepare_implementation;
      prepare_implementation;
      commit_implementation;
    ]
  in
  Rpc.Implementations.create_exn ~implementations
    ~on_unknown_rpc:`Close_connection

(* Read what client has requested and forwards the message back to client *)
let main_loop ~me ~host_and_ports () =
  let sequence_num = ref 0 in
  let where_to_connects =
    List.map host_and_ports ~f:Tcp.Where_to_connect.of_host_and_port
  in
  Pipe.iter request_reader ~f:(fun query ->
      match query with
      | Client query ->
          sequence_num := !sequence_num + 1;
          let request =
            Server_preprepare_rpcs.Request.
              { view = 0; message = query; sequence_number = !sequence_num }
          in
          Deferred.List.iter where_to_connects ~f:(fun where_to_connect ->
              let%bind connection = Rpc.Connection.client where_to_connect in
              match connection with
              | Ok connection ->
                  let _ =
                    Rpc.One_way.dispatch Server_preprepare_rpcs.rpc connection
                      request
                  in
                  Deferred.unit
              | Error _ -> Deferred.unit)
      | Preprepare _ -> Deferred.unit
      | Prepare _ -> Deferred.unit
      | Commit
          Server_commit_rpcs.Request.
            { replica_number; view; message; sequence_number } -> (
          ignore (replica_number, sequence_number);
          let Client_to_server_rpcs.Request.
                { operation; timestamp; name_of_client } =
            message
          in
          data := Interface.Operation.apply !data operation;
          let response =
            Client_to_server_rpcs.Response.create ~result:!data ~view ~timestamp
              ~replica_number:me
          in
          match
            Client_connection_manager.write_to_client ~name_of_client response
          with
          | Error _ -> Deferred.unit
          | Ok _ -> Deferred.unit ))

let command =
  Command.async ~summary:"Server"
    (let open Command.Let_syntax in
    let%map_open host_and_ports =
      flag "-host-and-ports" (listed host_and_port)
        ~doc:"PORTS ports of all servers"
    and me =
      flag "-me" (required int)
        ~doc:
          "INDEX index of the port associated with the current replica. This \
           is also used as the identifier of the replica, as known as the \
           replica number"
    in
    fun () ->
      let port = List.nth_exn host_and_ports me |> Host_and_port.port in
      let open Deferred.Let_syntax in
      let%bind _ =
        Tcp.Server.create ~on_handler_error:`Ignore
          (Tcp.Where_to_listen.of_port port) (fun _ r w ->
            Rpc.Connection.server_with_close r w ~implementations
              ~on_handshake_error:`Ignore ~connection_state:Fn.id)
      in
      don't_wait_for (main_loop ~me ~host_and_ports ());
      Deferred.never ())

let () = Command.run command

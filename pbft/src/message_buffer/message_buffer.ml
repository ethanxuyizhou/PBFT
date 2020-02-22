open Core
open Async
open Rpcs

(* Global data structures kept to facilitate asynchronous message sending and receiving *)
let client_request_reader, client_request_writer = Pipe.create ()

let server_response_reader, server_response_writer = Pipe.create ()

let browser_tab_writer_list, browser_tab_writer_mux =
  (ref Int.Map.empty, Mutex.create ())
  
(* End of global data structures*)

(* Kicks off the loop that reads what data needs to be sent to the client,
   and writes that data to all listening webapp browser tabs *)
let () =
  let rec send_data_updates_to_all_browser_tabs () =
    match%bind Pipe.read server_response_reader with
    | `Eof -> Deferred.unit
    | `Ok x ->
        Mutex.lock browser_tab_writer_mux;
        let%bind () =
          Deferred.Map.iter !browser_tab_writer_list ~f:(fun w ->
              Pipe.write_if_open w x)
        in
        Mutex.unlock browser_tab_writer_mux;
        send_data_updates_to_all_browser_tabs ()
  in
  don't_wait_for (send_data_updates_to_all_browser_tabs ())

let operation_implementation =
  Rpc.One_way.implement App_to_client_rpcs.operation_rpc (fun _state query ->
      Pipe.write_without_pushback_if_open client_request_writer query)

let data_implementation =
  Rpc.Pipe_rpc.implement App_to_client_rpcs.data_rpc (fun _state _query ->
      let r, w = Pipe.create () in
      Mutex.lock browser_tab_writer_mux;
      let key = Map.length !browser_tab_writer_list in
      browser_tab_writer_list :=
        Map.add_exn !browser_tab_writer_list ~key ~data:w;
      Mutex.unlock browser_tab_writer_mux;
      upon (Pipe.closed r) (fun () ->
          Mutex.lock browser_tab_writer_mux;
          browser_tab_writer_list := Map.remove !browser_tab_writer_list key;
          Mutex.unlock browser_tab_writer_mux);
      Deferred.return (Result.return r))

let implementations =
  Rpc.Implementations.create_exn
    ~implementations:[ operation_implementation; data_implementation ]
    ~on_unknown_rpc:`Close_connection

let send_request_to_pbft_servers ~addresses request =
  let send_request_to_address address =
    match%bind Rpc.Connection.client address with
    | Error _ -> Deferred.unit
    | Ok connection ->
        let (_ : unit Or_error.t) =
          Rpc.One_way.dispatch Client_to_server_rpcs.request_rpc connection
            request
        in
        Rpc.Connection.close connection
  in
  let key =
    Record_manager.Key.create (Client_to_server_rpcs.Request.timestamp request)
  in
  match%bind Record_manager.has_received_reply key with
  | false -> Deferred.List.iter addresses ~f:send_request_to_address
  | true -> Deferred.unit

let collect_commits_from_pbft_servers f addresses name =
  let rec loop address w =
    match%bind Rpc.Connection.client address with
    | Error _ ->
        let%bind () = after Time.Span.second in
        loop address w
    | Ok connection -> (
        match%bind
          Rpc.Pipe_rpc.dispatch Client_to_server_rpcs.response_rpc connection
            Client_to_server_rpcs.Hello.{ name_of_client = name }
        with
        | Error _ ->
            let%bind () = after Time.Span.second in
            loop address w
        | Ok r -> (
            match r with
            | Error _ -> Deferred.unit
            | Ok (r, _) ->
                let%bind () = Pipe.transfer_id r w in
                loop address w ) )
  in
  let pipe =
    List.map addresses ~f:(fun address ->
        let r, w = Pipe.create () in
        don't_wait_for (loop address w);
        r)
    |> Pipe.interleave
  in
  let%bind () = after Time.Span.second in
  Pipe.iter pipe ~f:(fun response ->
      let open Client_to_server_rpcs in
      let timestamp = Response.timestamp response in
      let replica_number = Response.replica_number response in
      let data = Response.result response in
      let key = Record_manager.Key.create timestamp in
      let%bind () = Record_manager.update key ~data ~replica_number in
      let%bind size = Record_manager.size key ~data in
      if size = f + 1 then Pipe.write_if_open server_response_writer data else Deferred.unit)

let command =
  Command.async ~summary:"Acts as a message buffer between PBFT servers and client webapp"
    (let open Command.Let_syntax in
    let%map_open host_and_ports =
      flag "-host-and-port" (listed host_and_port) ~doc:"Host_and_port of all servers"
    and name = flag "-name" (required string) ~doc:"Name of the client" in
    fun () ->
      let open Deferred.Let_syntax in
      let open Async_rpc_kernel in
      let f = (List.length host_and_ports - 1) / 3 in
      let addresses =
        List.map host_and_ports ~f:Tcp.Where_to_connect.of_host_and_port
      in
      don't_wait_for (collect_commits_from_pbft_servers f addresses name);
      don't_wait_for
        (Pipe.iter client_request_reader ~f:(fun operation' ->
             let request =
               Client_to_server_rpcs.Request.
                 {
                   operation = operation';
                   timestamp = Time.now ();
                   name_of_client = name;
                 }
             in
             send_request_to_pbft_servers ~addresses request));
      let%bind _ =
        Tcp.Server.create ~on_handler_error:`Ignore
          (Tcp.Where_to_listen.of_port 80) (fun _ reader writer ->
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
              upon (Pipe.closed ws_read) (fun () -> Pipe.close_read r1);
              upon (Pipe.closed ws_write) (fun () -> Pipe.close w2);
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
                     Pipe.write_if_open ws_write
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
open Core
open Async
open Rpcs
open Common

(* Global data structures kept to facilitate asynchronous message sending and receiving *)
let client_request_reader, client_request_writer = Pipe.create ()

let server_response_reader, server_response_writer = Pipe.create ()

let browser_tab_writer_list, browser_tab_writer_mux =
  (ref Int.Map.empty, Mutex.create ())

module Key_data = struct
  module Key = struct
    module S = struct
      type t = Time.t [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end

  module Data = struct
    module S = struct
      type t = Interface.Data.t [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module Log = Make_consensus_log (Key_data)

let record = ref (Log.create ())

(* End of global data structures*)

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

let send_request_to_pbft_servers ~num_of_faulty_nodes addresses request =
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
  let key = Client_to_server_rpcs.Request.timestamp request in
  match
    Log.has_reached_consensus !record ~key ~threshold:(num_of_faulty_nodes + 1)
  with
  | false -> Deferred.List.iter addresses ~f:send_request_to_address
  | true -> Deferred.unit

let collect_commits_from_pbft_servers ~num_of_faulty_nodes addresses name =
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
  Pipe.iter pipe ~f:(fun response ->
      let open Client_to_server_rpcs in
      let timestamp = Response.timestamp response in
      let replica_number = Response.replica_number response in
      let data = Response.result response in
      let key = timestamp in
      record := Log.update !record ~key ~data ~replica_number;
      let size = Log.size !record ~key ~data in
      if size = num_of_faulty_nodes + 1 then
        Pipe.write_if_open server_response_writer data
      else Deferred.unit)

(* Kicks off the loop that reads what data needs to be sent to the client,
   and writes that data to all listening webapp browser tabs *)
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

let command =
  Command.async
    ~summary:"Acts as a message buffer between PBFT servers and client webapp"
    (let open Command.Let_syntax in
    let%map_open host_and_ports =
      flag "-host-and-port" (listed host_and_port)
        ~doc:"Host_and_port of all servers"
    and name = flag "-name" (required string) ~doc:"Name of the client"
    and test = flag "-TEST" no_arg ~doc:"TEST" in
    fun () ->
      let open Deferred.Let_syntax in
      let addresses =
        List.map host_and_ports ~f:Tcp.Where_to_connect.of_host_and_port
      in
      let num_of_faulty_nodes =
        number_of_faulty_nodes ~n:(List.length addresses)
      in
      don't_wait_for
        (collect_commits_from_pbft_servers ~num_of_faulty_nodes addresses name);
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
             send_request_to_pbft_servers ~num_of_faulty_nodes addresses request));
      don't_wait_for (send_data_updates_to_all_browser_tabs ());
      if test then
        let port = int_of_string (Unix.getenv_exn "PBFT_TEST_CLIENT_PORT") in
        let%bind _ =
          Tcp.Server.create ~on_handler_error:`Ignore
            (Tcp.Where_to_listen.of_port port) (fun _ r w ->
              Rpc.Connection.server_with_close r w ~implementations
                ~on_handshake_error:`Ignore ~connection_state:Fn.id)
        in
        Deferred.never ()
      else
        let open Async_rpc_kernel in
        let%bind _ =
          Tcp.Server.create ~on_handler_error:`Ignore
            (Tcp.Where_to_listen.of_port 80) (fun _ reader writer ->
              let app_to_ws, ws_write = Pipe.create () in
              let ws_read, ws_to_app = Pipe.create () in
              don't_wait_for
                (let%bind _ =
                   Websocket_async.server ~reader ~writer ~app_to_ws ~ws_to_app
                     ()
                 in
                 Deferred.unit);
              let pipe_r, pipe_w =
                let r1, w1 = Pipe.create () in
                let r2, w2 = Pipe.create () in
                upon (Pipe.closed ws_read) (fun () -> Pipe.close_read r1);
                upon (Pipe.closed ws_write) (fun () -> Pipe.close w2);
                don't_wait_for
                  (Pipe.transfer ws_read w1
                     ~f:(fun Websocket.Frame.
                               { opcode; extension; final; content }
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
                ~connection_state:Fn.id ~on_handshake_error:`Ignore)
        in
        Deferred.never ())

let () = Command.run command

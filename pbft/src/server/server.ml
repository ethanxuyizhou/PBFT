open Core
open Async
open Rpcs
open Common

type request =
  | Client of Client_to_server_rpcs.Request.t
  | Preprepare of Server_preprepare_rpcs.Request.t
  | Prepare of Server_prepare_rpcs.Request.t
  | Commit of Server_commit_rpcs.Request.t

(* Global data structure *)

let data = ref (Interface.Data.init ())

let request_reader, request_writer = Pipe.create ()

let connection_states = Client_connection_manager.create ()

(* End of global data structre *)

let client_request_implementation =
  Rpc.One_way.implement Client_to_server_rpcs.request_rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Client query)))

let client_response_implementation =
  Rpc.Pipe_rpc.implement Client_to_server_rpcs.response_rpc
    (Client_connection_manager.establish_communication connection_states)

let preprepare_implementation =
  Rpc.One_way.implement Server_preprepare_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Preprepare query)))

let prepare_implementation =
  Rpc.One_way.implement Server_prepare_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Prepare query)))

let commit_implementation =
  Rpc.One_way.implement Server_commit_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Commit query)))

(*
let view_change_implementation =c
  Rpc.One_way.implement Server_view_change_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (View_change query)))

let new_view_implementation =
  Rpc.One_way.implement Server_new_view_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (New_view query)))
*)

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

module Key_data = struct
  module Key = struct
    module S = struct
      type t = { view : int; sequence_number : int } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end

  module Data = struct
    module S = struct
      type t = Client_to_server_rpcs.Request.t [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module Log = Make_consensus_log (Key_data)

(* Read what client has requested and forwards the message back to client *)
let main ~me ~host_and_ports () =
  let sequence_num = ref 0 in
  let current_view = ref 0 in
  let n = List.length host_and_ports in
  let num_of_faulty_nodes = number_of_faulty_nodes ~n in
  let where_to_connects =
    List.map host_and_ports ~f:Tcp.Where_to_connect.of_host_and_port
  in
  let preprepare_log = ref (Log.create ()) in
  let prepare_log = ref (Log.create ()) in
  let commit_log = ref (Log.create ()) in
  let rec loop where_to_connect r =
    match%bind Rpc.Connection.client where_to_connect with
    | Error _ -> loop where_to_connect r
    | Ok connection ->
        let rec sub_loop () =
          match%bind Pipe.read r with
          | `Eof -> Deferred.unit
          | `Ok query -> (
              match query connection with
              | Error _ ->
                  let%bind () = Rpc.Connection.close connection in
                  loop where_to_connect r
              | Ok _ -> sub_loop () )
        in
        sub_loop ()
  in
  let writes =
    let rws =
      List.map where_to_connects ~f:(fun where_to_connect ->
          let r, w = Pipe.create () in
          (where_to_connect, r, w))
    in
    List.iter rws ~f:(fun (where_to_connect, r, _) ->
        don't_wait_for (loop where_to_connect r));
    List.map rws ~f:(fun (_, _, w) -> w)
  in
  let is_leader view = view % n = me in
  Pipe.iter request_reader ~f:(fun query ->
      match query with
      | Client query ->
          if is_leader !current_view then (
            sequence_num := !sequence_num + 1;
            let request =
              Server_preprepare_rpcs.Request.
                {
                  leader_number = me;
                  view = !current_view;
                  message = query;
                  sequence_number = !sequence_num;
                }
            in
            List.iter writes ~f:(fun w ->
                Pipe.write_without_pushback w (fun connection ->
                    Rpc.One_way.dispatch Server_preprepare_rpcs.rpc connection
                      request));
            Deferred.unit )
          else Deferred.unit
      | Preprepare { leader_number; view; message; sequence_number } ->
          let accept =
            (view = !current_view && leader_number = !current_view % n)
            && Log.size !preprepare_log ~key:{ view; sequence_number }
                 ~data:message
               = 0
          in
          if accept then (
            preprepare_log :=
              Log.update !preprepare_log ~key:{ view; sequence_number }
                ~data:message ~replica_number:leader_number;
            let request =
              Server_prepare_rpcs.Request.create ~replica_number:me ~view
                ~message ~sequence_number
            in
            List.iter writes ~f:(fun w ->
                Pipe.write_without_pushback w (fun connection ->
                    Rpc.One_way.dispatch Server_prepare_rpcs.rpc connection
                      request));
            Deferred.unit )
          else Deferred.unit
      | Prepare { replica_number; view; message; sequence_number } ->
          if view = !current_view then (
            prepare_log :=
              Log.update !prepare_log ~key:{ view; sequence_number }
                ~data:message ~replica_number;
            let request =
              Server_commit_rpcs.Request.create ~replica_number:me ~view
                ~message ~sequence_number
            in
            if
              Log.size !prepare_log ~key:{ view; sequence_number } ~data:message
              = (2 * num_of_faulty_nodes) + 1
            then (
              List.iter writes ~f:(fun w ->
                  Pipe.write_without_pushback w (fun connection ->
                      Rpc.One_way.dispatch Server_commit_rpcs.rpc connection
                        request));
              Deferred.unit )
            else Deferred.unit )
          else Deferred.unit
      | Commit
          Server_commit_rpcs.Request.
            { replica_number; view; message; sequence_number } ->
          let Client_to_server_rpcs.Request.
                { operation; timestamp; name_of_client } =
            message
          in
          commit_log :=
            Log.update !commit_log ~key:{ view; sequence_number } ~data:message
              ~replica_number;
          if
            Log.size !commit_log ~key:{ view; sequence_number } ~data:message
            = (2 * num_of_faulty_nodes) + 1
          then (
            data := Interface.Operation.apply !data operation;
            let response =
              Client_to_server_rpcs.Response.create ~result:!data ~view
                ~timestamp ~replica_number:me
            in
            match
              Client_connection_manager.write_to_client connection_states
                ~name_of_client response
            with
            | Error _ -> Deferred.unit
            | Ok _ -> Deferred.unit )
          else Deferred.unit)

let command =
  Command.async ~summary:"Server"
    (let open Command.Let_syntax in
    let%map_open host_and_ports =
      flag "-host-and-port" (listed host_and_port)
        ~doc:"HOST_AND_PORTS ports of all servers"
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
      don't_wait_for (main ~me ~host_and_ports ());
      Deferred.never ())

let () = Command.run command

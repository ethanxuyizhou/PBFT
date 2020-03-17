open Core
open Async
open Rpcs
open Common

type request =
  | Client of Client_to_server_rpcs.Request.t
  | Preprepare of Server_preprepare_rpcs.Request.t
  | Prepare of Server_prepare_rpcs.Request.t
  | Commit of Server_commit_rpcs.Request.t
  | View_change of Server_view_change_rpcs.Request.t
  | New_view of Server_new_view_rpcs.Request.t
  | Checkpoint of Server_checkpoint_rpcs.Request.t

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

let view_change_implementation =
  Rpc.One_way.implement Server_view_change_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (View_change query)))

let new_view_implementation =
  Rpc.One_way.implement Server_new_view_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (New_view query)))

let checkpoint_implementation =
  Rpc.One_way.implement Server_checkpoint_rpcs.rpc (fun _state query ->
      don't_wait_for (Pipe.write request_writer (Checkpoint query)))

let implementations =
  let implementations =
    [
      client_request_implementation;
      client_response_implementation;
      preprepare_implementation;
      prepare_implementation;
      commit_implementation;
      view_change_implementation;
      new_view_implementation;
      checkpoint_implementation;
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
      type t = { message : Client_to_server_rpcs.Request.t }
      [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module Log = Make_consensus_log (Key_data)

module Checkpoint_key_data = struct
  module Key = struct
    module S = struct
      type t = { last_sequence_number : int } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end

  module Data = struct
    module S = struct
      type t = { state : Interface.Data.t } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module Checkpoint_log = Make_consensus_log (Checkpoint_key_data)

module View_change_key_data = struct
  module Key = struct
    module S = struct
      type t = { view : int } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end

  module Data = struct
    module S = struct
      type t = {
        sequence_number_of_last_checkpoint : int;
        prepares : Server_view_change_rpcs.Request.prepare_set list;
      }
      [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module View_change_log = Make_consensus_log (View_change_key_data)
module Timer = Make_timer (Client_to_server_rpcs.Request)

(* Necessary type definitions *)

type checkpoint = { last_sequence_number : int; state : Interface.Data.t }

type commit = { operation : Interface.Operation.t; name_of_client : string }

(* End of necessary type definitions *)

let main ~me ~host_and_ports () =
  (* meta data *)
  let sequence_num = ref 0 in
  let current_view = ref 0 in
  let n = List.length host_and_ports in
  let num_of_faulty_nodes = number_of_faulty_nodes ~n in
  let addresses =
    List.map host_and_ports ~f:Tcp.Where_to_connect.of_host_and_port
  in

  (* Client_to_server data *)
  let client_log = ref Client_to_server_rpcs.Request.Set.empty in

  (* Preprepare data *)
  let preprepare_log = ref (Log.create ()) in

  (* Prepare data *)
  let prepare_log = ref (Log.create ()) in

  (* Commit data *)
  let commit_log = ref (Log.create ()) in
  let commit_queue = ref (Queue.create ()) in
  let client_to_latest_timestamp = ref String.Map.empty in
  let last_committed_sequence_number = ref 0 in
  let timer = ref (Timer.create ()) in

  (* Checkpoint data *)
  let checkpoint_log = ref (Checkpoint_log.create ()) in
  let last_stable_checkpoint =
    ref { last_sequence_number = -1; state = Interface.Data.init () }
  in

  (* View change data *)
  let running = ref true in
  let view_change_log = ref (View_change_log.create ()) in

  let writes =
    List.map addresses ~f:(fun address -> write_to_address address)
  in
  let is_leader view = view % n = me in
  Pipe.iter request_reader ~f:(fun query ->
      if Timer.timeout !timer then (
        running := false;
        timer := Timer.create ();
        let prepares =
          let last_checkpoint_sequence_number =
            !last_stable_checkpoint.last_sequence_number
          in
          Log.filter_map !prepare_log
            ~f:(fun ~key ~data:{ message } ~voted_replicas ->
              let { Key_data.Key.view; sequence_number } = key in
              if
                List.length voted_replicas >= (2 * num_of_faulty_nodes) + 1
                && view > last_checkpoint_sequence_number
                && Log.has_key !preprepare_log ~key
              then
                Some
                  {
                    Server_view_change_rpcs.Request.preprepare =
                      Server_preprepare_rpcs.Request.create ~view ~message
                        ~sequence_number;
                    prepares =
                      List.map voted_replicas ~f:(fun replica_number ->
                          Server_prepare_rpcs.Request.create ~replica_number
                            ~view ~message ~sequence_number);
                  }
              else None)
        in
        List.iter writes ~f:(fun w ->
            Pipe.write_without_pushback w (fun connection ->
                Deferred.return
                  (Rpc.One_way.dispatch Server_view_change_rpcs.rpc connection
                     {
                       Server_view_change_rpcs.Request.view = !current_view + 1;
                       sequence_number_of_last_checkpoint =
                         !last_stable_checkpoint.last_sequence_number;
                       replica_number = me;
                       prepares;
                     }))) );
      match query with
      | Client query ->
          if
            !running
            && not
                 (Set.exists !client_log
                    ~f:(Client_to_server_rpcs.Request.equal query))
          then (
            client_log := Set.add !client_log query;
            if is_leader !current_view then (
              sequence_num := !sequence_num + 1;
              let request =
                Server_preprepare_rpcs.Request.create ~view:!current_view
                  ~message:query ~sequence_number:!sequence_num
              in
              List.iter writes ~f:(fun w ->
                  Pipe.write_without_pushback w (fun connection ->
                      Deferred.return
                        (Rpc.One_way.dispatch Server_preprepare_rpcs.rpc
                           connection request)));
              Deferred.unit )
            else (
              timer := Timer.set !timer ~key:query;
              Pipe.write_without_pushback
                (List.nth_exn writes (!current_view % n))
                (fun connection ->
                  Deferred.return
                    (Rpc.One_way.dispatch Client_to_server_rpcs.request_rpc
                       connection query));
              Deferred.unit ) )
          else Deferred.unit
      | Preprepare { view; message; sequence_number } ->
          if !running then
            let accept =
              view = !current_view
              && not
                   (Log.has_key !preprepare_log ~key:{ view; sequence_number })
            in
            if accept then (
              preprepare_log :=
                Log.insert !preprepare_log ~key:{ view; sequence_number }
                  ~data:{ message } ~replica_number:(view % n);
              let request =
                Server_prepare_rpcs.Request.create ~replica_number:me ~view
                  ~message ~sequence_number
              in
              List.iter writes ~f:(fun w ->
                  Pipe.write_without_pushback w (fun connection ->
                      Deferred.return
                        (Rpc.One_way.dispatch Server_prepare_rpcs.rpc connection
                           request)));
              Deferred.unit )
            else Deferred.unit
          else Deferred.unit
      | Prepare { replica_number; view; message; sequence_number } ->
          if !running && view = !current_view then (
            prepare_log :=
              Log.insert !prepare_log ~key:{ view; sequence_number }
                ~data:{ message } ~replica_number;
            let request =
              Server_commit_rpcs.Request.create ~replica_number:me ~view
                ~message ~sequence_number
            in
            let is_in_preprepare_log =
              Log.size !preprepare_log ~key:{ view; sequence_number }
                ~data:{ message }
              = 1
            in
            let can_prepare =
              Log.size !prepare_log ~key:{ view; sequence_number }
                ~data:{ message }
              = (2 * num_of_faulty_nodes) + 1
            in
            if is_in_preprepare_log && can_prepare then (
              List.iter writes ~f:(fun w ->
                  Pipe.write_without_pushback w (fun connection ->
                      Deferred.return
                        (Rpc.One_way.dispatch Server_commit_rpcs.rpc connection
                           request)));
              Deferred.unit )
            else Deferred.unit )
          else Deferred.unit
      | Commit
          {
            Server_commit_rpcs.Request.replica_number;
            view;
            message;
            sequence_number;
          } ->
          if !running then (
            let {
              Client_to_server_rpcs.Request.operation = _;
              timestamp;
              name_of_client;
            } =
              message
            in
            commit_log :=
              Log.insert !commit_log ~key:{ view; sequence_number }
                ~data:{ message } ~replica_number;
            let is_latest_timestamp =
              Map.find !client_to_latest_timestamp name_of_client
              |> Option.value_map ~default:true ~f:(fun previous_timestamp ->
                     Time.(previous_timestamp < timestamp))
            in
            let can_commit =
              Log.size !commit_log ~key:{ view; sequence_number }
                ~data:{ message }
              = (2 * num_of_faulty_nodes) + 1
            in

            if is_latest_timestamp && can_commit then (
              commit_queue :=
                Queue.insert !commit_queue ~pos:sequence_number message;
              if !last_committed_sequence_number + 1 = sequence_number then
                Queue.iter_from !commit_queue ~pos:sequence_number
                  ~f:(fun sequence_number
                          ( {
                              Client_to_server_rpcs.Request.operation;
                              timestamp;
                              name_of_client;
                            } as message )
                          ->
                    client_log := Set.add !client_log message;
                    data := Interface.Operation.apply !data operation;
                    client_to_latest_timestamp :=
                      Map.update
                        !client_to_latest_timestamp
                        name_of_client
                        ~f:
                          (Option.value_map ~f:(Time.max timestamp)
                             ~default:timestamp);
                    last_committed_sequence_number := sequence_number;
                    timer := Timer.cancel !timer ~key:message;
                    let response =
                      Client_to_server_rpcs.Response.create ~result:!data ~view
                        ~timestamp ~replica_number:me
                    in
                    Client_connection_manager.write_to_client connection_states
                      ~name_of_client response)
              else Deferred.unit )
            else Deferred.unit )
          else Deferred.unit
      | View_change
          { view; sequence_number_of_last_checkpoint; replica_number; prepares }
        ->
          view_change_log :=
            View_change_log.insert !view_change_log ~key:{ view }
              ~data:{ sequence_number_of_last_checkpoint; prepares }
              ~replica_number;
          if
            is_leader view
            && View_change_log.number_of_voted_replicas !view_change_log
                 ~key:{ view }
               >= 2 * num_of_faulty_nodes
          then (
            let data = View_change_log.find !view_change_log ~key:{ view } in
            ignore data;
            Deferred.unit )
          else Deferred.unit
      | New_view _ -> Deferred.unit
      | Checkpoint { last_sequence_number; state; replica_number } ->
          checkpoint_log :=
            Checkpoint_log.insert !checkpoint_log ~key:{ last_sequence_number }
              ~data:{ state } ~replica_number;
          let is_checkpoint_latest =
            last_sequence_number < !last_stable_checkpoint.last_sequence_number
          in
          let can_checkpoint =
            Checkpoint_log.size !checkpoint_log ~key:{ last_sequence_number }
              ~data:{ state }
            = (2 * num_of_faulty_nodes) + 1
          in
          if is_checkpoint_latest && can_checkpoint then (
            last_stable_checkpoint := { last_sequence_number; state };
            Deferred.unit )
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

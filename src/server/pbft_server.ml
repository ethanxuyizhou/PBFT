open Core
open Async
open Rpcs
open Common
open Logs

 type event =
  | Client of Client_to_server_rpcs.Request.t
  | Preprepare of Server_preprepare_rpcs.Request.t
  | Prepare of Server_prepare_rpcs.Request.t
  | Commit of Server_commit_rpcs.Request.t
  | View_change of Server_view_change_rpcs.Request.t
  | New_view of Server_new_view_rpcs.Request.t
  | Checkpoint of Server_checkpoint_rpcs.Request.t
  | Timeout

type t = {
  mutable data : Interface.Data.t;
  event_reader : event Pipe.Reader.t;
  event_writer : event Pipe.Writer.t;
  connection_manager : Client_connection_manager.t;
}

let create () =
  let event_reader, event_writer = Pipe.create () in
  {
    data = Interface.Data.init ();
    event_reader;
    event_writer;
    connection_manager = Client_connection_manager.create ();
  }

let client_request_implementation =
  Rpc.One_way.implement Client_to_server_rpcs.request_rpc (fun t query ->
      don't_wait_for (Pipe.write t.event_writer (Client query)))

let client_response_implementation =
  Rpc.Pipe_rpc.implement Client_to_server_rpcs.response_rpc (fun t reader ->
      Client_connection_manager.establish_communication t.connection_manager
        reader)

let preprepare_implementation =
  Rpc.One_way.implement Server_preprepare_rpcs.rpc (fun t query ->
      don't_wait_for (Pipe.write t.event_writer (Preprepare query)))

let prepare_implementation =
  Rpc.One_way.implement Server_prepare_rpcs.rpc (fun t query ->
      don't_wait_for (Pipe.write t.event_writer (Prepare query)))

let commit_implementation =
  Rpc.One_way.implement Server_commit_rpcs.rpc (fun t query ->
      don't_wait_for (Pipe.write t.event_writer (Commit query)))

let view_change_implementation =
  Rpc.One_way.implement Server_view_change_rpcs.rpc (fun t query ->
      don't_wait_for (Pipe.write t.event_writer (View_change query)))

let new_view_implementation =
  Rpc.One_way.implement Server_new_view_rpcs.rpc (fun t query ->
      don't_wait_for (Pipe.write t.event_writer (New_view query)))

let checkpoint_implementation =
  Rpc.One_way.implement Server_checkpoint_rpcs.rpc (fun t query ->
      don't_wait_for (Pipe.write t.event_writer (Checkpoint query)))

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

module Timer = Make_timer (Client_to_server_rpcs.Operation)

(* Necessary type definitions *)
type checkpoint = { last_sequence_number : int; state : Interface.Data.t }

(* End of necessary type definitions *)

let main t ~me ~host_and_ports () =
  let n = List.length host_and_ports in
  let num_of_faulty_nodes = number_of_faulty_nodes ~n in
  let addresses =
    List.map host_and_ports ~f:Tcp.Where_to_connect.of_host_and_port
  in
  let clients =
    List.map addresses ~f:(fun address -> write_to_address address)
  in
  let is_leader view = view % n = me in
  Pipe.iter t.event_reader ~f:(fun query ->
      match query with
      | Timeout ->
          running := false;
          Timer.reset !timer;
          let prepared_messages_after_last_stable_checkpoint =
            let last_checkpoint_sequence_number =
              !last_stable_checkpoint.last_sequence_number
            in
            Preprepare_log.filter_map !prepare_log
              ~f:(fun ~key ~data:{ message } ~voted_replicas ->
                let { Key_data.Key.view; sequence_number } = key in
                if
                  List.length voted_replicas >= (2 * num_of_faulty_nodes) + 1
                  && view > last_checkpoint_sequence_number
                  && Preprepare_log.has_key !preprepare_log ~key
                then
                  Some
                    Server_view_change_rpcs.Request.
                      {
                        preprepare =
                          Server_preprepare_rpcs.Request.create ~view ~message
                            ~sequence_number;
                        prepares =
                          List.map voted_replicas ~f:(fun replica_number ->
                              Server_prepare_rpcs.Request.create ~replica_number
                                ~view ~message ~sequence_number);
                      }
                else None)
          in
          List.iteri clients ~f:(fun i client ->
              if not (Int.equal i me) then
                Pipe.write_without_pushback client (fun connection ->
                    Deferred.return
                      (Rpc.One_way.dispatch Server_view_change_rpcs.rpc
                         connection
                         {
                           Server_view_change_rpcs.Request.view =
                             !current_view + 1;
                           sequence_number_of_last_checkpoint =
                             !last_stable_checkpoint.last_sequence_number;
                           replica_number = me;
                           prepared_messages_after_last_stable_checkpoint;
                         })));
          Deferred.unit
      | Client query -> (
          match query with
          | No_op -> Deferred.unit
          | Op query ->
              if
                !running
                && not
                     (Set.exists !client_log
                        ~f:(Client_to_server_rpcs.Operation.equal query))
              then (
                client_log := Set.add !client_log query;
                if is_leader !current_view then (
                  sequence_num := !sequence_num + 1;
                  let request =
                    Server_preprepare_rpcs.Request.create ~view:!current_view
                      ~message:(Op query) ~sequence_number:!sequence_num
                  in
                  List.iter clients ~f:(fun client ->
                      Pipe.write_without_pushback client (fun connection ->
                          Deferred.return
                            (Rpc.One_way.dispatch Server_preprepare_rpcs.rpc
                               connection request)));
                  Deferred.unit )
                else (
                  Timer.set !timer ~key:query ~f:(fun () ->
                      Pipe.write_without_pushback t.event_writer Timeout);
                  Pipe.write_without_pushback
                    (List.nth_exn clients (!current_view % n))
                    (fun connection ->
                      Deferred.return
                        (Rpc.One_way.dispatch Client_to_server_rpcs.request_rpc
                           connection (Op query)));
                  Deferred.unit ) )
              else Deferred.unit )
      | Preprepare { view; message; sequence_number } ->
          printf
            "Preprepare: %d. Current view: %d. Me: %d. Sequence_number: %d\n"
            view !current_view me sequence_number;
          if !running then
            let accept =
              view = !current_view
              && not
                   (Preprepare_log.has_key !preprepare_log
                      ~key:{ view; sequence_number })
            in
            if accept then (
              preprepare_log :=
                Preprepare_log.insert !preprepare_log
                  ~key:{ view; sequence_number } ~data:{ message }
                  ~replica_number:(view % n);
              let request =
                Server_prepare_rpcs.Request.create ~replica_number:me ~view
                  ~message ~sequence_number
              in
              List.iter clients ~f:(fun client ->
                  Pipe.write_without_pushback client (fun connection ->
                      Deferred.return
                        (Rpc.One_way.dispatch Server_prepare_rpcs.rpc connection
                           request)));
              Deferred.unit )
            else Deferred.unit
          else Deferred.unit
      | Prepare { replica_number; view; message; sequence_number } ->
          if !running && view = !current_view then (
            prepare_log :=
              Prepare_log.insert !prepare_log ~key:{ view; sequence_number }
                ~data:{ message } ~replica_number;
            let request =
              Server_commit_rpcs.Request.create ~replica_number:me ~view
                ~message ~sequence_number
            in
            let is_in_preprepare_log =
              Prepare_log.size !preprepare_log ~key:{ view; sequence_number }
                ~data:{ message }
              = 1
            in
            let can_prepare =
              Prepare_log.size !prepare_log ~key:{ view; sequence_number }
                ~data:{ message }
              = (2 * num_of_faulty_nodes) + 1
            in
            if is_in_preprepare_log && can_prepare then (
              List.iter clients ~f:(fun client ->
                  Pipe.write_without_pushback client (fun connection ->
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
            match message with
            | No_op -> Deferred.unit
            | Op
                ( {
                    Client_to_server_rpcs.Operation.operation = _;
                    timestamp;
                    name_of_client;
                  } as message ) ->
                commit_log :=
                  Commit_log.insert !commit_log ~key:{ view; sequence_number }
                    ~data:{ message } ~replica_number;
                let is_latest_timestamp =
                  Map.find !client_to_latest_timestamp name_of_client
                  |> Option.value_map ~default:true
                       ~f:(fun previous_timestamp ->
                         Time.(previous_timestamp < timestamp))
                in
                let can_commit =
                  Commit_log.size !commit_log ~key:{ view; sequence_number }
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
                                  Client_to_server_rpcs.Operation.operation;
                                  timestamp;
                                  name_of_client;
                                } as message )
                              ->
                        client_log := Set.add !client_log message;
                        t.data <- Interface.Operation.apply t.data operation;
                        client_to_latest_timestamp :=
                          Map.update
                            !client_to_latest_timestamp
                            name_of_client
                            ~f:
                              (Option.value_map ~f:(Time.max timestamp)
                                 ~default:timestamp);
                        last_committed_sequence_number := sequence_number;
                        Timer.cancel !timer ~key:message;
                        let response =
                          Client_to_server_rpcs.Response.create ~result:t.data
                            ~view ~timestamp ~replica_number:me
                        in
                        Client_connection_manager.write_to_client
                          t.connection_manager ~name_of_client response)
                  else Deferred.unit )
                else Deferred.unit )
          else Deferred.unit
      | View_change
          ( {
              view;
              sequence_number_of_last_checkpoint = _;
              replica_number;
              prepared_messages_after_last_stable_checkpoint = _;
            } as view_change ) ->
          printf "View change\n";
          (* TODO verify view change message 
           Things to check:
           1. Digest is correct
           2. Prepared messages have higher sequence number than seq number of last stable checkpoint
        *)
          view_change_log :=
            View_change_log.insert !view_change_log ~key:{ view }
              ~data:view_change ~replica_number;
          if
            is_leader view
            && View_change_log.number_of_voted_replicas !view_change_log
                 ~key:{ view }
               >= 2 * num_of_faulty_nodes
          then (
            current_view := view;
            let data = View_change_log.find !view_change_log ~key:{ view } in

            let min_s =
              List.map data ~f:(fun x -> x.sequence_number_of_last_checkpoint)
              |> List.max_elt ~compare:Int.compare
            in
            let preprepares =
              List.map data ~f:(fun x ->
                  x.prepared_messages_after_last_stable_checkpoint)
              |> List.concat
              |> List.map ~f:(fun preprepare_set -> preprepare_set.preprepare)
            in
            let max_s =
              List.map preprepares ~f:(fun preprepare ->
                  preprepare.sequence_number)
              |> List.max_elt ~compare:Int.compare
            in
            (sequence_num :=
               match (min_s, max_s) with
               | None, None -> !sequence_num
               | Some min_s, None -> min_s
               | _, Some max_s -> max_s);
            let view_change_messages =
              View_change_log.find !view_change_log ~key:{ view }
            in
            let request =
              Option.value_map max_s
                ~default:
                  Server_new_view_rpcs.Request.
                    { view; view_change_messages; preprepares = [] }
                ~f:(fun max_s ->
                  let min_s = Option.value min_s ~default:0 in

                  let preprepares =
                    List.range ~start:`exclusive ~stop:`inclusive min_s max_s
                    |> List.map ~f:(fun sequence_number ->
                           let message =
                             List.find_map preprepares ~f:(fun preprepare ->
                                 if preprepare.sequence_number = sequence_number
                                 then Some preprepare.message
                                 else None)
                             |> Option.value
                                  ~default:Client_to_server_rpcs.Request.(No_op)
                           in
                           Server_preprepare_rpcs.Request.create ~view ~message
                             ~sequence_number)
                  in
                  Server_new_view_rpcs.Request.
                    { view; view_change_messages; preprepares })
            in
            List.iter clients ~f:(fun client ->
                Pipe.write_without_pushback client (fun connection ->
                    Deferred.return
                      (Rpc.One_way.dispatch Server_new_view_rpcs.rpc connection
                         request)));
            running := true;
            Deferred.unit )
          else Deferred.unit
      | New_view { view; view_change_messages = _; preprepares } ->
          (* TODO: authenticate the view change messages and the preprepare messages *)
          printf "new view\n";
          running := true;
          current_view := view;
          List.iter preprepares ~f:(fun preprepare ->
              Pipe.write_without_pushback t.event_writer (Preprepare preprepare));
          Deferred.unit
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
            (* TODO discard all preprepare, prepare, commit messages with earlier checkpoints *)
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
              ~on_handshake_error:`Ignore
              ~connection_state:(fun (_ : Rpc.Connection.t) ->
                let t = create () in
                don't_wait_for (main t ~me ~host_and_ports ());
                t))
      in
      Deferred.never ())

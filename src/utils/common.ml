open Core
open Async
include Common_intf

let number_of_faulty_nodes ~n = (n - 1) / 3

let rec transfer_message_from_pipe_to_address ~timeout reader address =
  match%bind Rpc.Connection.client address with
  | Error _ ->
      let%bind () = after timeout in
      transfer_message_from_pipe_to_address ~timeout reader address
  | Ok connection ->
      let rec loop () =
        match%bind Pipe.read reader with
        | `Eof -> Deferred.unit
        | `Ok f -> (
            match%bind f connection with
            | Error _ ->
                let%bind () = Rpc.Connection.close connection in
                let%bind () = after timeout in
                transfer_message_from_pipe_to_address ~timeout reader address
            | Ok _ -> loop () )
      in
      loop ()

let write_to_address ?(timeout = Time.Span.of_sec 0.5) address =
  let r, w = Pipe.create () in
  don't_wait_for (transfer_message_from_pipe_to_address ~timeout r address);
  w

let rec ping_for_message_stream ~timeout writer ping address =
  match%bind Rpc.Connection.client address with
  | Error _ ->
      let%bind () = after timeout in
      ping_for_message_stream ~timeout writer ping address
  | Ok connection -> (
      match%bind ping connection with
      | Error _ ->
          let%bind () = after timeout in
          ping_for_message_stream ~timeout writer ping address
      | Ok reader -> (
          match reader with
          | Error _ -> Deferred.unit
          | Ok (reader, _) ->
              let%bind () = Pipe.transfer_id reader writer in
              ping_for_message_stream ~timeout writer ping address ) )

let read_from_address ?(timeout = Time.Span.of_sec 0.5) ping address =
  let r, w = Pipe.create () in
  don't_wait_for (ping_for_message_stream ~timeout w ping address);
  r

module Queue = struct
  type 'a t = 'a Int.Map.t

  let create () = Int.Map.empty

  let iter_from t ~pos ~f =
    let current_pos = ref pos in
    let rec loop () =
      match Map.find t !current_pos with
      | None -> Deferred.unit
      | Some x ->
          let%bind () = f !current_pos x in
          current_pos := !current_pos + 1;
          loop ()
    in
    loop ()

  let insert t ~pos data = Map.update t pos ~f:(fun _ -> data)
end

module Make_timer (Data : Comparable) = struct
  type t = { data : unit Deferred.t Data.Map.t ref; mux : Mutex.t }

  let create () = { data = ref Data.Map.empty; mux = Mutex.create () }

  let set { data; mux } ~key ~f =
    Mutex.lock mux;
    data :=
      Map.update !data key
        ~f:
          (Option.value
             ~default:
               (let%map () = after Time.Span.second in
                Mutex.lock mux;
                if Map.mem !data key then f ();
                Mutex.unlock mux));
    Mutex.unlock mux

  let cancel { data; mux } ~key =
    Mutex.lock mux;
    data := Map.remove !data key;
    Mutex.unlock mux

  let reset { data; mux } =
    Mutex.lock mux;
    data := Data.Map.empty;
    Mutex.unlock mux
end

module Make_consensus_log (Key_data : Key_data) = struct
  open Key_data

  module Value = struct
    type t = { data_to_votes : int list Data.Map.t; voted_replicas : Int.Set.t }
    [@@deriving fields]

    let init ~data ~replica_number =
      {
        data_to_votes = Data.Map.singleton data [ replica_number ];
        voted_replicas = Int.Set.singleton replica_number;
      }

    let insert t ~data ~replica_number =
      if Set.exists t.voted_replicas ~f:(Int.equal replica_number) then t
      else
        let data_to_votes =
          Data.Map.update t.data_to_votes data
            ~f:
              (Option.value_map ~default:[ replica_number ] ~f:(fun x ->
                   replica_number :: x))
        in
        let voted_replicas = Int.Set.add t.voted_replicas replica_number in
        { data_to_votes; voted_replicas }

    let size t ~data =
      Option.value_map (Map.find t.data_to_votes data) ~f:List.length ~default:0

    let exists t ~f = Map.exists t.data_to_votes ~f

    let filter_mapi t ~f = Map.filter_mapi t.data_to_votes ~f
  end

  type t = { record : Value.t Key.Map.t; mux : Mutex.t }

  let create () = { record = Key.Map.empty; mux = Mutex.create () }

  let insert { record; mux } ~key ~data ~replica_number =
    Mutex.lock mux;
    let record =
      Map.update record key
        ~f:
          (Option.value_map
             ~default:(Value.init ~data ~replica_number)
             ~f:(Value.insert ~data ~replica_number))
    in
    Mutex.unlock mux;
    { record; mux }

  let size { record; mux } ~key ~data =
    Mutex.lock mux;
    let size =
      Map.find record key |> Option.value_map ~default:0 ~f:(Value.size ~data)
    in
    Mutex.unlock mux;
    size

  let has_key { record; mux } ~key =
    Mutex.lock mux;
    let exists = Map.find record key |> Option.is_some in
    Mutex.unlock mux;
    exists

  let has_reached_consensus { record; mux } ~key ~threshold =
    Mutex.lock mux;
    let result =
      Map.find record key
      |> Option.value_map ~default:false
           ~f:
             (Value.exists ~f:(fun voted_replicas ->
                  List.length voted_replicas >= threshold))
    in
    Mutex.unlock mux;
    result

  let number_of_voted_replicas { record; mux } ~key =
    Mutex.lock mux;
    let result =
      Map.find record key
      |> Option.value_map ~default:0 ~f:(fun value ->
             Value.voted_replicas value |> Set.length)
    in
    Mutex.unlock mux;
    result

  let find { record; mux } ~key =
    Mutex.lock mux;
    let result =
      Map.find record key
      |> Option.value_map ~default:[] ~f:(fun value ->
             Value.data_to_votes value |> Data.Map.keys)
    in
    Mutex.unlock mux;
    result

  let filter { record; mux } ~f =
    Mutex.lock mux;
    let record = Map.filter_keys record ~f in
    Mutex.unlock mux;
    { record; mux = Mutex.create () }

  let filter_map { record; mux } ~f =
    Mutex.lock mux;
    let result =
      Map.mapi record ~f:(fun ~key ~data ->
          let f = f ~key in
          Value.filter_mapi data ~f:(fun ~key ~data ->
              f ~data:key ~voted_replicas:data)
          |> Map.data)
      |> Map.data |> List.concat
    in
    Mutex.unlock mux;
    result
end

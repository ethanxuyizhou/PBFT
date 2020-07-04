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
  type t = { data : unit Deferred.t Data.Map.t ref }

  let create () = { data = ref Data.Map.empty }

  let set { data } ~key ~f =
    data :=
      Map.update !data key
        ~f:
          (Option.value
             ~default:
               (let%map () = after Time.Span.second in
                if Map.mem !data key then f ()))

  let cancel { data } ~key = data := Map.remove !data key

  let reset { data } = data := Data.Map.empty
end

module Make_consensus_log (Key_data : Key_data) = struct
  open Key_data

  module Value = struct
    type t = { data_to_votes : int list Data.Map.t; voted_replicas : Int.Set.t }
    [@@deriving fields, sexp]

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

  type t = { record : Value.t Key.Map.t }

  let create () = { record = Key.Map.empty }

  let insert { record } ~key ~data ~replica_number =
    let record =
      Map.update record key
        ~f:
          (Option.value_map
             ~default:(Value.init ~data ~replica_number)
             ~f:(Value.insert ~data ~replica_number))
    in
    { record }

  let size { record } ~key ~data =
    let size =
      Map.find record key |> Option.value_map ~default:0 ~f:(Value.size ~data)
    in
    size

  let has_key { record } ~key =
    let exists = Map.find record key |> Option.is_some in
    exists

  let has_reached_consensus { record } ~key ~threshold =
    let result =
      Map.find record key
      |> Option.value_map ~default:false
           ~f:
             (Value.exists ~f:(fun voted_replicas ->
                  List.length voted_replicas >= threshold))
    in
    result

  let number_of_voted_replicas { record } ~key =
    let result =
      Map.find record key
      |> Option.value_map ~default:0 ~f:(fun value ->
             Value.voted_replicas value |> Set.length)
    in
    result

  let find { record } ~key =
    let result =
      Map.find record key
      |> Option.value_map ~default:[] ~f:(fun value ->
             Value.data_to_votes value |> Data.Map.keys)
    in
    result

  let filter { record } ~f =
    let record = Map.filter_keys record ~f in
    { record }

  let filter_map { record } ~f =
    let result =
      Map.mapi record ~f:(fun ~key ~data ->
          let f = f ~key in
          Value.filter_mapi data ~f:(fun ~key ~data ->
              f ~data:key ~voted_replicas:data)
          |> Map.data)
      |> Map.data |> List.concat
    in
    result
end

open Core
open Async
include Common_intf

let number_of_faulty_nodes ~n = (n - 1) / 3

let rec transfer_message_from_pipe_to_address ?(timeout = Time.Span.second)
    reader address =
  match%bind Rpc.Connection.client address with
  | Error _ ->
      let%bind () = after timeout in
      transfer_message_from_pipe_to_address reader address
  | Ok connection ->
      let rec loop () =
        match%bind Pipe.read reader with
        | `Eof -> Deferred.unit
        | `Ok f -> (
            match%bind f connection with
            | Error _ ->
                let%bind () = Rpc.Connection.close connection in
                let%bind () = after Time.Span.second in
                transfer_message_from_pipe_to_address reader address
            | Ok _ -> loop () )
      in
      loop ()

module Make_consensus_log (Key_data : Key_data) = struct
  open Key_data

  module Value = struct
    type t = { data_to_votes : int Data.Map.t; voted_replicas : Int.Set.t }

    let init ~data ~replica_number =
      {
        data_to_votes = Data.Map.singleton data 1;
        voted_replicas = Int.Set.singleton replica_number;
      }

    let update t ~data ~replica_number =
      if Set.exists t.voted_replicas ~f:(Int.equal replica_number) then t
      else
        let data_to_votes =
          Data.Map.update t.data_to_votes data
            ~f:(Option.value_map ~default:1 ~f:(fun x -> x + 1))
        in
        let voted_replicas = Int.Set.add t.voted_replicas replica_number in
        { data_to_votes; voted_replicas }

    let size t ~data = Option.value (Map.find t.data_to_votes data) ~default:0

    let exists t ~f = Map.exists t.data_to_votes ~f
  end

  type t = { record : Value.t Key.Map.t; mux : Mutex.t }

  let create () = { record = Key.Map.empty; mux = Mutex.create () }

  let update { record; mux } ~key ~data ~replica_number =
    Mutex.lock mux;
    let record =
      Map.update record key
        ~f:
          (Option.value_map
             ~default:(Value.init ~data ~replica_number)
             ~f:(Value.update ~data ~replica_number))
    in
    Mutex.unlock mux;
    { record; mux }

  let size { record; mux } ~key ~data =
    Mutex.lock mux;
    let size =
      Key.Map.find record key
      |> Option.value_map ~default:0 ~f:(Value.size ~data)
    in
    Mutex.unlock mux;
    size

  let has_reached_consensus { record; mux } ~key ~threshold =
    Mutex.lock mux;
    let result =
      Key.Map.find record key
      |> Option.value_map ~default:false
           ~f:(Value.exists ~f:(fun i -> i >= threshold))
    in
    Mutex.unlock mux;
    result
end

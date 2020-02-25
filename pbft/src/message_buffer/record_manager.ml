open Core
open Rpcs

module Key = struct
  type t = Time.t

  let create timestamp = timestamp
end

module Value = struct
  type t = {
    data_to_votes : int Interface.Data.Map.t;
    voted_replicas : Int.Set.t;
  }

  let init ~data ~replica_number =
    {
      data_to_votes = Interface.Data.Map.singleton data 1;
      voted_replicas = Int.Set.singleton replica_number;
    }

  let update t ~data ~replica_number =
    if Set.exists t.voted_replicas ~f:(Int.equal replica_number) then t
    else
      let data_to_votes =
        Interface.Data.Map.update t.data_to_votes data
          ~f:(Option.value_map ~default:1 ~f:(fun x -> x + 1))
      in
      let voted_replicas = Int.Set.add t.voted_replicas replica_number in
      { data_to_votes; voted_replicas }

  let size t ~data = Option.value (Map.find t.data_to_votes data) ~default:0
end

type t = { record : Value.t Time.Map.t; mux : Mutex.t }

let create () = { record = Time.Map.empty; mux = Mutex.create () }

let has_received_reply { record; mux } ~key =
  Mutex.lock mux;
  let received = Map.mem record key in
  Mutex.unlock mux;
  received

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
    Option.value_map (Time.Map.find record key) ~default:0 ~f:(Value.size ~data)
  in
  Mutex.unlock mux;
  size

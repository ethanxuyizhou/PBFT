open Core_kernel
open Async_kernel
open Rpcs

module Key = struct
  type t = Time.t 
  let create timestamp = timestamp

end

module Value = struct
  type t = 
    { data_to_votes : int Interface.Data.Map.t
    ; voted_replicas : Int.Set.t}
  
  let init ~data ~replica_number = 
    { data_to_votes = Interface.Data.Map.singleton data 1; voted_replicas =  Int.Set.singleton replica_number}

  let update t ~data ~replica_number = 
    if Set.exists t.voted_replicas ~f:(Int.equal replica_number)
    then 
      t
    else
      let data_to_votes = Interface.Data.Map.update t.data_to_votes data ~f:(Option.value_map ~default:1~f:(fun x -> x + 1)) in
      let voted_replicas = Int.Set.add t.voted_replicas replica_number in
      { data_to_votes ; voted_replicas}

  let size t ~data =
    Option.value (Map.find t.data_to_votes data) ~default:0

end

let record = ref (Map.empty (module Time))

let mux_r, mux_w = Pipe.create ()

let () = Pipe.write_without_pushback mux_w ()

let has_received_reply key =
  let%map _ = Pipe.read mux_r in
  let received = Map.mem !record key in
  Pipe.write_without_pushback mux_w ();
  received

let update key ~data ~replica_number =
  let%map _ = Pipe.read mux_r in
  record :=
    Map.update !record key
      ~f:(Option.value_map ~default:(Value.init ~data ~replica_number) ~f:(Value.update ~data ~replica_number));
  Pipe.write_without_pushback mux_w ()

let size key ~data =
  let%map _ = Pipe.read mux_r in
  let length =
    Option.value_map (Map.find !record key) ~default:0 ~f:(Value.size ~data)  in
  Pipe.write_without_pushback mux_w (); length

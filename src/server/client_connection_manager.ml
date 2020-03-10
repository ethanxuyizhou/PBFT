open Core
open Async
open Rpcs

type t = {
  data : Client_to_server_rpcs.Response.t Pipe.Writer.t String.Map.t ref;
  mux : Mutex.t;
}

let create () = { data = ref String.Map.empty; mux = Mutex.create () }

let write_to_client { data; mux } message ~name_of_client =
  Mutex.lock mux;
  let pipe = Map.find !data name_of_client in
  Mutex.unlock mux;
  match pipe with
  | None -> Deferred.unit
  | Some pipe -> Pipe.write_if_open pipe message

let establish_communication { data; mux } _state query =
  let name_of_client = Client_to_server_rpcs.Hello.name_of_client query in
  let r, w = Pipe.create () in
  Mutex.lock mux;
  data := String.Map.set !data ~key:name_of_client ~data:w;
  Mutex.unlock mux;
  Deferred.return (Result.return r)

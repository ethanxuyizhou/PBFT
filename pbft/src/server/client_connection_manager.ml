open Core
open Async
open Rpcs

let mux = Mutex.create ()

let data = ref String.Map.empty

let write_to_client message ~name_of_client =
  Mutex.lock mux;
  let pipe = Map.find !data name_of_client in
  Mutex.unlock mux;
  match pipe with
  | None -> Or_error.errorf "No client with name %s" name_of_client
  | Some pipe -> Or_error.return (Pipe.write pipe message)

let establish_communication _state query =
  let name_of_client = Client_to_server_rpcs.Hello.name_of_client query in
  let r, w = Pipe.create () in
  Mutex.lock mux;
  data := String.Map.set !data ~key:name_of_client ~data:w;
  Mutex.unlock mux;
  Deferred.return (Result.return r)

open Core
open Async
open Rpcs

type t = {
  data : Client_to_server_rpcs.Response.t Pipe.Writer.t String.Map.t ref;
}

let create () = { data = ref String.Map.empty }

let write_to_client { data } message ~name_of_client =
  let pipe = Map.find !data name_of_client in
  match pipe with
  | None -> Deferred.unit
  | Some pipe -> Pipe.write_if_open pipe message

let establish_communication { data } query =
  let name_of_client = Client_to_server_rpcs.Hello.name_of_client query in
  let r, w = Pipe.create () in
  data := String.Map.set !data ~key:name_of_client ~data:w;
  Deferred.return (Result.return r)

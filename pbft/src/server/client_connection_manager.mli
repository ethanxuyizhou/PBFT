open Core
open Async
open Rpcs

val write_to_client :
  Client_to_server_rpcs.Response.t ->
  name_of_client:string ->
  unit Deferred.t Or_error.t

val establish_communication :
  'connection_state ->
  Client_to_server_rpcs.Hello.t ->
  (Client_to_server_rpcs.Response.t Pipe.Reader.t, Error.t) Result.t Deferred.t

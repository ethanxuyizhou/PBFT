open Core
open Async
open Rpcs

type t

val create : unit -> t

val write_to_client :
  t ->
  Client_to_server_rpcs.Response.t ->
  name_of_client:string ->
  unit Deferred.t

val establish_communication :
  t ->
  'connection_state ->
  Client_to_server_rpcs.Hello.t ->
  (Client_to_server_rpcs.Response.t Pipe.Reader.t, Error.t) Result.t Deferred.t

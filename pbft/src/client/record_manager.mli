open Core_kernel
open Async_kernel
open Rpcs

module Key : sig
  type t

  val create : Time.t -> t
end

val has_received_reply : Key.t -> bool Deferred.t

val update : Key.t -> data:Interface.Data.t -> replica_number:int -> unit Deferred.t

val size : Key.t -> data:Interface.Data.t -> int Deferred.t

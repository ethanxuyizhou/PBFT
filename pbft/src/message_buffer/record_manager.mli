open Core
open Rpcs

module Key : sig
  type t

  val create : Time.t -> t
end

type t

val create : unit -> t

val has_received_reply : t -> key:Key.t -> bool

val update : t -> key:Key.t -> data:Interface.Data.t -> replica_number:int -> t

val size : t -> key:Key.t -> data:Interface.Data.t -> int

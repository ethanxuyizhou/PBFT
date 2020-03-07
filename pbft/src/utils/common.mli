open Core
open Async

(* Calculate maximum number of nodes PBFT can tolerate given total number of nodes n *)
val number_of_faulty_nodes : n:int -> int

(* Repeatedly try to send message to a given address*)
val transfer_message_from_pipe_to_address :
  ?timeout:Time.Span.t ->
  (Rpc.Connection.t -> unit Or_error.t Deferred.t) Pipe.Reader.t ->
  Tcp.Where_to_connect.inet ->
  unit Deferred.t

val ping_for_message_stream :
  ?timeout:Time.Span.t ->
  'a Pipe.Writer.t ->
  (Rpc.Connection.t -> ('a Pipe.Reader.t * 'b, 'c) result Or_error.t Deferred.t) ->
  Tcp.Where_to_connect.inet ->
  unit Deferred.t

module Queue : sig
  type 'a t

  val create : unit -> 'a t

  val iter_from :
    'a t -> pos:int -> f:(int -> 'a -> unit Deferred.t) -> unit Deferred.t

  val insert : 'a t -> pos:int -> 'a -> 'a t
end

(* Thread-safe log for storing data to achieve PBFT consensus. *)
module Make_consensus_log (S : Common_intf.Key_data) : sig
  type t

  val create : unit -> t

  val update : t -> key:S.Key.t -> data:S.Data.t -> replica_number:int -> t

  val size : t -> key:S.Key.t -> data:S.Data.t -> int

  val has_reached_consensus : t -> key:S.Key.t -> threshold:int -> bool

  val key_exists : t -> key:S.Key.t -> bool
end

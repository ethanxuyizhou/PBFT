open Core
open Async

(* Calculate maximum number of nodes PBFT can tolerate given total number of nodes n *)
val number_of_faulty_nodes : n:int -> int

(* Repeatedly try to send message to a given address*)
val transfer_message_from_pipe_to_address :
  timeout:Time.Span.t ->
  (Rpc.Connection.t -> unit Or_error.t Deferred.t) Pipe.Reader.t ->
  Tcp.Where_to_connect.inet ->
  unit Deferred.t

val write_to_address :
  ?timeout:Time.Span.t ->
  Tcp.Where_to_connect.inet ->
  (Rpc.Connection.t -> unit Or_error.t Deferred.t) Pipe.Writer.t

val ping_for_message_stream :
  timeout:Time.Span.t ->
  'a Pipe.Writer.t ->
  (Rpc.Connection.t -> ('a Pipe.Reader.t * 'b, 'c) result Or_error.t Deferred.t) ->
  Tcp.Where_to_connect.inet ->
  unit Deferred.t

val read_from_address :
  ?timeout:Time.Span.t ->
  (Rpc.Connection.t -> ('a Pipe.Reader.t * 'b, 'c) result Or_error.t Deferred.t) ->
  Tcp.Where_to_connect.inet ->
  'a Pipe.Reader.t

module Queue : sig
  type 'a t

  val create : unit -> 'a t

  val iter_from :
    'a t -> pos:int -> f:(int -> 'a -> unit Deferred.t) -> unit Deferred.t

  val insert : 'a t -> pos:int -> 'a -> 'a t
end

module Make_timer (S : Comparable) : sig
  type t

  val create : unit -> t

  val set : t -> key:S.t -> f:(unit -> unit) -> unit

  val cancel : t -> key:S.t -> unit

  val reset : t -> unit
end

(* Thread-safe log for storing data to achieve PBFT consensus. *)
module Make_consensus_log (S : Common_intf.Key_data) : sig
  type t

  val create : unit -> t

  val insert : t -> key:S.Key.t -> data:S.Data.t -> replica_number:int -> t

  val size : t -> key:S.Key.t -> data:S.Data.t -> int

  val has_reached_consensus : t -> key:S.Key.t -> threshold:int -> bool

  val has_key : t -> key:S.Key.t -> bool

  val number_of_voted_replicas : t -> key:S.Key.t -> int

  val find : t -> key:S.Key.t -> S.Data.t list

  val filter : t -> f:(S.Key.t -> bool) -> t

  val filter_map :
    t ->
    f:(key:S.Key.t -> data:S.Data.t -> voted_replicas:int list -> 'a option) ->
    'a list
end

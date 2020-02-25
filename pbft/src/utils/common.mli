val number_of_faulty_nodes : n:int -> int

module Log (S : Common_intf.Key_data) : sig
  type t

  val create : unit -> t

  val update : t -> key:S.Key.t -> data:S.Data.t -> replica_number:int -> t

  val size : t -> key:S.Key.t -> data:S.Data.t -> int

  val has_reached_consensus : t -> key:S.Key.t -> threshold:int -> bool
end

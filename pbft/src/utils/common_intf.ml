open Core

module type Key_data = sig
  module Key : sig
    type t [@@deriving sexp, compare]

    include Comparable.S with type t := t
  end

  module Data : sig
    type t [@@deriving sexp, compare]

    include Comparable.S with type t := t
  end
end

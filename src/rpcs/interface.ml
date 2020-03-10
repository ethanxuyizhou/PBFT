open Core_kernel

module Data = struct
  module S = struct
    type t = int [@@deriving bin_io, sexp, compare]

    let init () = 0
  end

  include S
  include Comparable.Make (S)
end

module Operation = struct
  type t = Add of int | Multiply of int [@@deriving bin_io, sexp, compare]

  let apply data t = match t with Add x -> data + x | Multiply x -> data * x
end

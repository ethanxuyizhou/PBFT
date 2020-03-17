open Core_kernel
open Async_rpc_kernel

module Request = struct
  type prepare_set = {
    preprepare : Server_preprepare_rpcs.Request.t;
    prepares : Server_prepare_rpcs.Request.t list;
  }
  [@@deriving bin_io, sexp, compare]

  type t = {
    view : int;
    sequence_number_of_last_checkpoint : int;
    replica_number : int;
    prepares : prepare_set list;
  }
  [@@deriving bin_io]
end

let rpc =
  Rpc.One_way.create ~name:"view-change" ~version:1 ~bin_msg:Request.bin_t

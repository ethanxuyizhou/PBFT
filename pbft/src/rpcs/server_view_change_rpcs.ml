open Core_kernel
open Async_rpc_kernel

module Request = struct
  type t = {
    view : int;
    sequence_number_of_last_checkpoint : int;
    replica_number : int;
  }
  [@@deriving bin_io]
end

let rpc =
  Rpc.One_way.create ~name:"view-change" ~version:1 ~bin_msg:Request.bin_t

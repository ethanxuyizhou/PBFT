open Core_kernel
open Async_rpc_kernel

module Request = struct
  type t = {
    last_sequence_number : int;
    state : Interface.Data.t;
    replica_number : int;
  }
  [@@deriving bin_io]

  let create ~last_sequence_number ~state ~replica_number =
    { last_sequence_number; state; replica_number }
end

let rpc =
  Rpc.One_way.create ~name:"checkpoint-rpc" ~version:1 ~bin_msg:Request.bin_t

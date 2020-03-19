open Core_kernel
open Async_rpc_kernel

module Request = struct
  type t = {
    view : int;
    view_change_messages : Server_view_change_rpcs.Request.t list;
    preprepares : Server_preprepare_rpcs.Request.t list;
  }
  [@@deriving bin_io]
end

let rpc = Rpc.One_way.create ~name:"new-view" ~version:1 ~bin_msg:Request.bin_t

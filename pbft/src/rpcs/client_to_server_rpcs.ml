open Core_kernel
open Async_rpc_kernel
open Interface

module Request = struct
  type t = {
    operation : Operation.t;
    timestamp : Time.t;
    name_of_client : string;
  }
  [@@deriving bin_io, fields]
end

module Hello = struct
  type t = { name_of_client : string } [@@deriving bin_io, fields]
end

module Response = struct
  type t = {
    result : Data.t;
    view : int;
    timestamp : Time.t;
    replica_number : int;
  }
  [@@deriving bin_io, fields, compare]
end

let request_rpc =
  Rpc.One_way.create ~name:"request" ~version:1 ~bin_msg:Request.bin_t

let response_rpc =
  Rpc.Pipe_rpc.create ~name:"response" ~version:1 ~bin_query:Hello.bin_t
    ~bin_response:Response.bin_t ~bin_error:Error.bin_t ()

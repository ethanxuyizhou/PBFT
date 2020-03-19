open Core_kernel
open Async_rpc_kernel
open Interface

module Operation = struct
  module S = struct
    type t = {
      operation : Operation.t;
      timestamp : Time.Stable.With_utc_sexp.V2.t;
      name_of_client : string;
    }
    [@@deriving bin_io, fields, sexp, compare]
  end

  include S
  include Comparable.Make (S)
end

module Request = struct
  module S = struct
    type t = No_op | Op of Operation.t [@@deriving bin_io, sexp, compare]
  end

  include S
  include Comparable.Make (S)
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

  let create ~result ~view ~timestamp ~replica_number =
    { result; view; timestamp; replica_number }
end

let request_rpc =
  Rpc.One_way.create ~name:"request" ~version:1 ~bin_msg:Request.bin_t

let response_rpc =
  Rpc.Pipe_rpc.create ~name:"response" ~version:1 ~bin_query:Hello.bin_t
    ~bin_response:Response.bin_t ~bin_error:Error.bin_t ()

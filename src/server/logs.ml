open Core
open Rpcs
open Common

module Key_data = struct
  module Key = struct
    module S = struct
      type t = { view : int; sequence_number : int } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end

  module Data = struct
    module S = struct
      type t = { message : Client_to_server_rpcs.Request.t }
      [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module Preprepare_log = Make_consensus_log (Key_data)
module Prepare_log = Make_consensus_log (Key_data)

module Commit_key_data = struct
  module Key = struct
    module S = struct
      type t = { view : int; sequence_number : int } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end

  module Data = struct
    module S = struct
      type t = { message : Client_to_server_rpcs.Operation.t }
      [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module Commit_log = Make_consensus_log (Commit_key_data)

module Checkpoint_key_data = struct
  module Key = struct
    module S = struct
      type t = { last_sequence_number : int } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end

  module Data = struct
    module S = struct
      type t = { state : Interface.Data.t } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module Checkpoint_log = Make_consensus_log (Checkpoint_key_data)

module View_change_key_data = struct
  module Key = struct
    module S = struct
      type t = { view : int } [@@deriving sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end

  module Data = struct
    module S = struct
      type t = Server_view_change_rpcs.Request.t
      [@@deriving bin_io, sexp, compare]
    end

    include S
    include Comparable.Make (S)
  end
end

module View_change_log = Make_consensus_log (View_change_key_data)

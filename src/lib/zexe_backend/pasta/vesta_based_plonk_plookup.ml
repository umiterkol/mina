open Core_kernel
open Zexe_backend_common
open Basic
module Field = Fp
module Curve = Vesta

module Bigint = struct
  module R = struct
    include Field.Bigint

    let of_data _ = failwith __LOC__

    let to_field = Field.of_bigint

    let of_field = Field.to_bigint
  end
end

let field_size : Bigint.R.t = Field.size

module Verification_key = struct
  type t = Marlin_plonk_bindings.Pasta_plookup_fp_verifier_index.t

  let to_string _ = failwith __LOC__

  let of_string _ = failwith __LOC__

  let shifts = Marlin_plonk_bindings.Pasta_plookup_fp_verifier_index.shifts
end

module R1CS_constraint_system =
  Plonk_plookup_constraint_system.Make
    (Field)
    (Marlin_plonk_bindings.Pasta_plookup_fp_index.Gate_vector)
    (struct
      let params =
        Sponge.Params.(
          map pasta_p5 ~f:(fun x ->
              Field.of_bigint (Bigint256.of_decimal_string x) ))
    end)

module Var = Var

let lagrange : int -> Marlin_plonk_bindings.Pasta_fp_urs.Poly_comm.t array =
  let open Marlin_plonk_bindings.Types in
  Memo.general ~hashable:Int.hashable (fun domain_log2 ->
      Array.map
        Precomputed.Lagrange_precomputations.(
          vesta.(index_of_domain_log2 domain_log2))
        ~f:(fun unshifted ->
          { Poly_comm.unshifted=
              Array.map unshifted ~f:(fun c -> Or_infinity.Finite c)
          ; shifted= None } ) )

let with_lagrange f (vk : Verification_key.t) =
  f (lagrange vk.domain.log_size_of_group) vk

let with_lagranges f (vks : Verification_key.t array) =
  let lgrs =
    Array.map vks ~f:(fun vk -> lagrange vk.domain.log_size_of_group)
  in
  f lgrs vks

module Rounds = Rounds.Wrap

module Keypair = Dlog_plonk_plookup_based_keypair.Make (struct
  open Marlin_plonk_bindings

  let name = "vesta_plookup"

  module Rounds = Rounds
  module Urs = Pasta_fp_urs
  module Index = Pasta_plookup_fp_index
  module Curve = Curve
  module Poly_comm = Fp_poly_comm
  module Scalar_field = Field
  module Verifier_index = Pasta_plookup_fp_verifier_index
  module Gate_vector = Pasta_plookup_fp_index.Gate_vector
  module Constraint_system = R1CS_constraint_system
end)

module Proof = Plonk_plookup_dlog_proof.Make (struct
  open Marlin_plonk_bindings

  let id = "pasta_vesta_plookup"

  module Scalar_field = Field
  module Base_field = Fq

  module Backend = struct
    include Pasta_plookup_fp_proof

    let verify = with_lagrange verify

    let batch_verify = with_lagranges batch_verify

    let create_aux ~f:create (pk : Keypair.t) primary auxiliary prev_chals
        prev_comms =
      let external_values i =
        let open Field.Vector in
        if i = 0 then Field.one
        else if i - 1 < length primary then get primary (i - 1)
        else get auxiliary (i - 1 - length primary)
      in
      let witness =
        R1CS_constraint_system.compute_witness pk.cs external_values
      in
      let n = Pasta_plookup_fp_index.domain_d1_size pk.index in
      let len = Array.length witness in




(*

      printf "DOMAIN SIZE %d" n;
      print_endline "";
      printf "WITNESS LENGTH %d" (Array.length witness);
      print_endline "";
      print_endline "";
      print_endline "";


      print_endline "*****WITNESS*****";
      Array.iteri witness ~f:(fun i x ->
      (
        print_endline (Sexp.to_string ([%sexp_of:  int] i));
        print_endline (Sexp.to_string ([%sexp_of:  Fp.t array] x))
      ));

*)




      let of_witness j =
        Array.init n ~f:(fun i ->
            if i < len then witness.(i).(j) else Field.zero )
      in
      let auxiliary_input =
        (of_witness 0, of_witness 1, of_witness 2, of_witness 3, of_witness 4)
      in
      create pk.index ~primary_input:(Field.Vector.create ()) ~auxiliary_input
        ~prev_challenges:prev_chals ~prev_sgs:prev_comms

    let create_async (pk : Keypair.t) primary auxiliary prev_chals prev_comms =
      create_aux pk primary auxiliary prev_chals prev_comms
        ~f:(fun pk
           ~primary_input
           ~auxiliary_input
           ~prev_challenges
           ~prev_sgs
           ->
          Async.In_thread.run (fun () ->
              create pk ~primary_input ~auxiliary_input ~prev_challenges
                ~prev_sgs ) )

    let create (pk : Keypair.t) primary auxiliary prev_chals prev_comms =
      create_aux pk primary auxiliary prev_chals prev_comms ~f:create
  end

  module Verifier_index = Pasta_plookup_fp_verifier_index
  module Index = Keypair

  module Evaluations_backend = struct
    type t =
      Scalar_field.t
      Marlin_plonk_bindings.Types.Plonk_plookup_proof.Evaluations.t
  end

  module Opening_proof_backend = struct
    type t =
      ( Scalar_field.t
      , Curve.Affine.Backend.t )
      Marlin_plonk_bindings.Types.Plonk_plookup_proof.Opening_proof.t
  end

  module Poly_comm = Fp_poly_comm
  module Curve = Curve
end)

module Proving_key = struct
  type t = Keypair.t

  include Core_kernel.Binable.Of_binable
            (Core_kernel.Unit)
            (struct
              type nonrec t = t

              let to_binable _ = ()

              let of_binable () = failwith "TODO"
            end)

  let is_initialized _ = `Yes

  let set_constraint_system _ _ = ()

  let to_string _ = failwith "TODO"

  let of_string _ = failwith "TODO"
end

module Oracles = Plookup_dlog_oracles.Make (struct
  module Verifier_index = Verification_key
  module Field = Field
  module Proof = Proof

  module Backend = struct
    include Marlin_plonk_bindings.Pasta_plookup_fp_oracles

    let create = with_lagrange create
  end
end)
use crate::inner_product_proof::*;
use crypto_common::*;
use crypto_common_derive::*;
use curve_arithmetic::Curve;

#[derive(Clone, Serialize, SerdeBase16Serialize, Debug)]
#[allow(non_snake_case)]
pub struct SetMembershipProof<C: Curve> {
    /// Commitment to the indicator function
    A:        C,
    /// Commitment to the blinding factors in s_L and s_R
    S:        C,
    /// Commitment to the t_1 coefficient of polynomial t(x)
    T_1:      C,
    /// Commitment to the t_2 coefficient of polynomial t(x)
    T_2:      C,
    /// Evaluation of t(x) at the challenge point x
    tx:       C::Scalar,
    /// Blinding factor for the commitment to tx
    tx_tilde: C::Scalar,
    /// Blinding factor for the commitment to the inner-product arguments
    e_tilde:  C::Scalar,
    /// Inner product proof
    ip_proof: InnerProductProof<C>,
}
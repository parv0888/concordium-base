use byteorder::ReadBytesExt;
use failure::Fallible;

use ff::PrimeField;
use pairing::{
    bls12_381::{Fq12, FqRepr, Fr, FrRepr, G1Affine, G1Compressed, G2Affine, G2Compressed, G1, G2},
    CurveAffine, CurveProjective, EncodedPoint,
};

use crate::serialize::*;

impl Deserial for Fr {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<Fr> {
        let mut frrepr: FrRepr = FrRepr([0u64; 4]);
        let mut i = true;
        // Read the scalar in big endian.
        // FIXME: Here we always set the first bit to 0. This is not desirable,
        // and we should rework this particular aspect. In particular, having it
        // like so can cause subtle issues when we hash elements.
        for digit in frrepr.as_mut().iter_mut().rev() {
            *digit = source.get()?;
            if i {
                *digit &= !(1 << 63);
                i = false;
            }
        }
        Ok(Fr::from_repr(frrepr)?)
    }
}

impl Serial for Fr {
    fn serial<B: Buffer>(&self, out: &mut B) {
        let frpr = &self.into_repr();
        for a in frpr.as_ref().iter().rev() {
            a.serial(out);
        }
    }
}

impl Deserial for G1 {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<G1> {
        let mut g = G1Compressed::empty();
        source.read_exact(g.as_mut())?;
        Ok(g.into_affine()?.into_projective())
    }
}

impl Serial for G1 {
    fn serial<B: Buffer>(&self, out: &mut B) {
        let g = self.into_affine().into_compressed();
        let g_bytes = g.as_ref();
        if let Err(e) = out.write_all(g_bytes) {
            panic!(
                "Precondition violated. Buffer should be safe to write {}.",
                e
            );
        }
    }
}

impl Deserial for G1Affine {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<G1Affine> {
        let mut g = G1Compressed::empty();
        source.read_exact(g.as_mut())?;
        Ok(g.into_affine()?)
    }
}

impl Serial for G1Affine {
    fn serial<B: Buffer>(&self, out: &mut B) {
        let g = self.into_compressed();
        let g_bytes = g.as_ref();
        if let Err(e) = out.write_all(g_bytes) {
            panic!(
                "Precondition violated. Buffer should be safe to write {}.",
                e
            );
        }
    }
}

impl Deserial for G2 {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<G2> {
        let mut g = G2Compressed::empty();
        source.read_exact(g.as_mut())?;
        Ok(g.into_affine()?.into_projective())
    }
}

impl Serial for G2 {
    fn serial<B: Buffer>(&self, out: &mut B) {
        let g = self.into_affine().into_compressed();
        let g_bytes = g.as_ref();
        if let Err(e) = out.write_all(g_bytes) {
            panic!(
                "Precondition violated. Buffer should be safe to write {}.",
                e
            );
        }
    }
}

impl Deserial for G2Affine {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<G2Affine> {
        let mut g = G2Compressed::empty();
        source.read_exact(g.as_mut())?;
        Ok(g.into_affine()?)
    }
}

impl Serial for G2Affine {
    fn serial<B: Buffer>(&self, out: &mut B) {
        let g = self.into_compressed();
        let g_bytes = g.as_ref();
        if let Err(e) = out.write_all(g_bytes) {
            panic!(
                "Precondition violated. Buffer should be safe to write {}.",
                e
            );
        }
    }
}

/// This implementation is ad-hoc, using the fact that Fq12 is defined
/// via that specific tower of extensions (of degrees) 2 -> 3 -> 2,
/// and the specific representation of those fields.
/// We use big-endian representation all the way down to the field Fq.
impl Serial for Fq12 {
    fn serial<B: Buffer>(&self, out: &mut B) {
        // coefficients in the extension F_6
        let c0_6 = self.c0;
        let c1_6 = self.c1;

        let coeffs = [
            // coefficients of c1_6 in the extension F_2
            c1_6.c2, c1_6.c1, c1_6.c0, // coefficients of c0_6 in the extension F_2
            c0_6.c2, c0_6.c1, c0_6.c0,
        ];
        for p in coeffs.iter() {
            let repr_c1 = FqRepr::from(p.c1);
            let repr_c0 = FqRepr::from(p.c0);
            for d in repr_c1.as_ref().iter() {
                d.serial(out);
            }
            for d in repr_c0.as_ref().iter() {
                d.serial(out);
            }
        }
    }
}

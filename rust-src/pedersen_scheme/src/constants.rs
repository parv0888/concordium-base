// -*- mode: rust; -*-
//
// This file is part of concordium_crypto
// Copyright (c) 2019 - 
// See LICENSE for licensing information.
//
// Authors:
// - bm@concordium.com

//! Common constants 


//length of prf in bytes
//pub const COMMITMENT_KEY_LENGTH: usize = 48*2;

//length of a commitment
pub const COMMITMENT_LENGTH: usize = 48;

//length of randomness 
pub const RANDOMNESS_LENGTH: usize = FIELD_ELEMENT_LENGTH;

//size of hiding prarmeter in bytes
//this is the size of compressed gropu element
//pub const HIDING_PARAM_LENGTH: usize= 48;

//length of gruop element in bytes
pub const GROUP_ELEMENT_LENGTH: usize = 48;


//length of field element in bytes
pub const FIELD_ELEMENT_LENGTH: usize = 32;

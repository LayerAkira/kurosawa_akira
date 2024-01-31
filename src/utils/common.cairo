// use serde::Serde;
// use starknet::ContractAddress;
// use core::fmt;
// use result::Result;

// fn min(a: u256, b: u256) -> u256 {
//     if a > b {
//         b
//     } else {
//         a
//     }
// }

// impl DisplayContractAddress of fmt::Display<ContractAddress> {
//     fn fmt(self: @ContractAddress, ref f: fmt::Formatter) -> Result<(), fmt::Error> {
//         let a: felt252 = (*self).into();
//         a.fmt(ref f)
//     }
// }



use serde::Serde;
use starknet::ContractAddress;

#[derive(Copy, Drop, starknet::Store, Serde, PartialEq)]
struct Rate {
    base_amount:u256,
    quote_amount:u256
}



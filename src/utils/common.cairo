use serde::Serde;
use starknet::ContractAddress;

fn min(a: u256, b: u256) -> u256 {
    if a > b {
        b
    } else {
        a
    }
}

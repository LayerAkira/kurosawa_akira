use serde::Serde;
use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct ChainCtx {
    caller: ContractAddress,
    value: u256,
    block: u64,
    timestamp: u64,
    gas_price: u256,
    tx_index: u256,
}

fn min(a: u256, b: u256) -> u256 {
    if a > b {
        b
    } else {
        a
    }
}

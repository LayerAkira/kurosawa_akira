use serde::Serde;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SlowModeDelay {
    block: u64,
    ts: u64,
}

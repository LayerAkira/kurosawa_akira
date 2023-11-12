use core::array::ArrayTrait;
use serde::Serde;
use starknet::ContractAddress;

fn min(a: u256, b: u256) -> u256 {
    if a > b {
        b
    } else {
        a
    }
}

fn pow_ten(pow: u8) -> u256{
    if pow == 0{
        return 1;
    }
    else{
        return 10 * pow_ten(pow - 1);
    }
}

fn get_market_ids_from_tuple(market_ids: (bool, bool)) -> Array<u16>{
    let (x, y) = market_ids;
    let mut res: Array<u16> = ArrayTrait::new();
    if x{
        res.append(0);
    }
    if x{
        res.append(1);
    }
    return res;
}

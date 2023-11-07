use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct GasFee {
    gas_per_swap: u256,
    fee_token: ContractAddress,
    max_gas_price: u256,
    conversion_rate: u256,
    external_call: bool,
}


impl ZeroableImpl of Zeroable<GasFee> {
    fn is_zero(self: GasFee) -> bool {
        self == self.zero()
    }
    fn zero(self: GasFee) -> GasFee {
        let zero_address = starknet::contract_address_try_from_felt252(0).unwrap();
        let zero_u256: u256 = 0;
        GasFee {
            gas_per_swap: zero_u256,
            fee_token: zero_address,
            max_gas_price: zero_u256,
            conversion_rate: zero_u256,
            external_call: false
        }
    }
}

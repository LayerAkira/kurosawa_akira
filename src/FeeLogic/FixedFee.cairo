use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct FixedFee {
    recipient: ContractAddress,
    fee_token: ContractAddress,
    pbips: u256,
    external_call: bool,
}

impl ZeroableImpl of Zeroable<FixedFee> {
    fn is_zero(self: FixedFee) -> bool {
        self == self.zero()
    }
    fn zero(self: FixedFee) -> FixedFee {
        let zero_adress = starknet::contract_address_try_from_felt252(0).unwrap();
        let zero_u256: u256 = 0;
        FixedFee {
            recipient: zero_adress, fee_token: zero_adress, pbips: zero_u256, external_call: false
        }
    }
}

use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_burn;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_mint;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::Zeroable;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct FixedFee {
    recipient: ContractAddress,
    fee_token: ContractAddress,
    pbips: u256,
    external_call: bool,
}


fn apply_fixed_fee_involved(
    ref state: ContractState, user: ContractAddress, fixedFee: FixedFee, feeable_qty: u256
) {
    if fixedFee.pbips == 0 {
        return;
    }
    let fee = (feeable_qty * fixedFee.pbips - 1) / 1000000 + 1;
    if fixedFee.external_call {
        IERC20Dispatcher { contract_address: fixedFee.fee_token }
            .transferFrom(user, fixedFee.recipient, fee);
    } else {
        _burn(ref state, user, fee, fixedFee.fee_token);
        _mint(ref state, fixedFee.recipient, fee, fixedFee.fee_token);
    }
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

use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_burn;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_mint;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_exchange_address_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_WRAPPED_NATIVE_CHAIN_COIN_read;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct GasFee {
    gas_per_swap: u256,
    fee_token: ContractAddress,
    max_gas_price: u256,
    conversion_rate: u256,
    external_call: bool,
}
const WEI_IN_ETH: u256 = 1000000000000000000;


fn validate_and_apply_gas_fee(
    ref state: ContractState, user: ContractAddress, gas_fee: GasFee, cur_gas_price: u256
) {
    if cur_gas_price == 0 {
        return;
    }
    if gas_fee.gas_per_swap == 0 {
        return;
    }
    assert(gas_fee.max_gas_price >= cur_gas_price, 'gas_prc <= user stated prc');
    let spend_native = gas_fee.gas_per_swap * cur_gas_price;
    let wrapped_native_token = _WRAPPED_NATIVE_CHAIN_COIN_read(ref state);
    if ((gas_fee.fee_token == wrapped_native_token) & !gas_fee.external_call) {
        _burn(ref state, user, spend_native, gas_fee.fee_token);
        _mint(ref state, _exchange_address_read(ref state), spend_native, gas_fee.fee_token);
        return;
    } else if ((gas_fee.fee_token == wrapped_native_token) & gas_fee.external_call) {
        IERC20Dispatcher { contract_address: gas_fee.fee_token }
            .transferFrom(user, _exchange_address_read(ref state), spend_native);
        return;
    }
    let spend_converted = (spend_native * gas_fee.conversion_rate - 1) / WEI_IN_ETH + 1;
    if !gas_fee.external_call {
        _burn(ref state, user, spend_converted, gas_fee.fee_token);
        _mint(ref state, _exchange_address_read(ref state), spend_converted, gas_fee.fee_token);
        return;
    }
    IERC20Dispatcher { contract_address: gas_fee.fee_token }
        .transferFrom(user, _exchange_address_read(ref state), spend_converted);
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

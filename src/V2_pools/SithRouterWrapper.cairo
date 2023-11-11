use serde::Serde;
use starknet::ContractAddress;
use starknet::contract_address_to_felt252;
use array::ArrayTrait;

use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapper;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;

use debug::PrintTrait;

#[starknet::contract]
mod SithWrapper {
    use super::SwapExactInfo;

    use starknet::ContractAddress;
    use starknet::contract_address_to_felt252;

    #[storage]
    struct Storage {
        router: ContractAddress
    }

    #[starknet::interface]
    trait SithWrapperPair<T> {
        fn getToken0(self: @T) -> ContractAddress;
        fn swap(
            self: @T,
            amount0_out: u256,
            amount1_out: u256,
            to: ContractAddress,
            data: Array::<felt252>
        );
        fn getAmountOut(self: @T, amountIn: u256, token_in: ContractAddress) -> u256;
    }

    #[external(v0)]
    impl SithWrapperImpl of super::RouterWrapper<ContractState> {
        fn swap(ref self: ContractState, swap_info: SwapExactInfo, recipient: ContractAddress) {
            let pair = SithWrapperPairDispatcher { contract_address: swap_info.pool };
            if pair.getToken0() == swap_info.token_in {
                return pair.swap(0, swap_info.amount_out_min, recipient, ArrayTrait::new());
            } else {
                return pair.swap(swap_info.amount_out_min, 0, recipient, ArrayTrait::new());
            }
        }

        fn get_amount_out(self: @ContractState, swap_info: SwapExactInfo) -> u256 {
            let pair = SithWrapperPairDispatcher { contract_address: swap_info.pool };
            return pair.getAmountOut(swap_info.amount_in_pool, swap_info.token_in);
        }
    }
}

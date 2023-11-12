use serde::Serde;
use starknet::ContractAddress;
use starknet::contract_address_to_felt252;
use array::ArrayTrait;

use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapper;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;

use debug::PrintTrait;

#[starknet::contract]
mod TenKWrapper {
    use super::SwapExactInfo;

    use starknet::ContractAddress;
    use starknet::contract_address_to_felt252;

    #[storage]
    struct Storage {
        router: ContractAddress
    }

    #[starknet::interface]
    trait TenKRealRouter<T> {
        fn getAmountOut(self: @T, amountIn: u256, reserveIn: felt252, reserveOut: felt252) -> u256;
    }
    #[starknet::interface]
    trait TenKRealPair<T> {
        fn token0(self: @T) -> ContractAddress;
        fn getReserves(self: @T) -> (felt252, felt252, felt252);
        fn swap(self: @T, amount0Out: u256, amount1Out: u256, to: ContractAddress);
    }
    #[constructor]
    fn constructor(ref self: ContractState, router_address: ContractAddress) {
        self.router.write(router_address)
    }

    #[external(v0)]
    impl TenKWrapperInpl of super::RouterWrapper<ContractState> {
        fn swap(ref self: ContractState, swap_info: SwapExactInfo, recipient: ContractAddress) {
            let pair = TenKRealPairDispatcher { contract_address: swap_info.pool };
            if pair.token0() == swap_info.token_in {
                return pair.swap(0, swap_info.amount_out_min, recipient);
            } else {
                return pair.swap(swap_info.amount_out_min, 0, recipient);
            }
        }

        fn get_amount_out(self: @ContractState, swap_info: SwapExactInfo) -> u256 {
            let executor = TenKRealRouterDispatcher { contract_address: self.router.read() };
            let pair = TenKRealPairDispatcher { contract_address: swap_info.pool };
            let (supply_0, supply_1, _) = pair.getReserves();
            if pair.token0() == swap_info.token_in {
                return executor.getAmountOut(swap_info.amount_in_pool, supply_0, supply_1);
            } else {
                return executor.getAmountOut(swap_info.amount_in_pool, supply_1, supply_0);
            }
        }
    }
}

use serde::Serde;
use starknet::ContractAddress;
use starknet::contract_address_to_felt252;
use array::ArrayTrait;

use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapper;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;

use debug::PrintTrait;

#[starknet::contract]
mod JediWrapper {
    use super::SwapExactInfo;

    use starknet::ContractAddress;
    use starknet::contract_address_to_felt252;
   
    #[storage]
    struct Storage {
        router: ContractAddress
    }

    #[starknet::interface]
    trait JediRealRouter<T> {
        fn get_amount_out(self: @T, amountIn: u256, reserveIn: u256, reserveOut: u256) -> u256;
    }
    #[starknet::interface]
    trait JediIPair<T> {
        
        fn token0(self: @T) -> ContractAddress;
        fn get_reserves(self: @T) -> (u256,u256,felt252);
        fn swap(self: @T,amount0Out:u256, amount1Out: u256, to: ContractAddress,  data:Array::<felt252>);
    }
    #[constructor]
    fn constructor(ref self: ContractState, router_address: ContractAddress) {
        self.router.write(router_address)
    }


    #[external(v0)]
    impl JediWrapperInpl of super::RouterWrapper<ContractState> {
        fn swap(ref self: ContractState, swap_info: SwapExactInfo, recipient: ContractAddress) {
            let pair = JediIPairDispatcher { contract_address: swap_info.pool };
            if pair.token0() == swap_info.token_in {
                return pair.swap(0, swap_info.amount_out_min, recipient, ArrayTrait::new());
            } else {
                 return pair.swap(swap_info.amount_out_min,0, recipient, ArrayTrait::new());
            }

        }

        fn get_amount_out(self: @ContractState, swap_info: SwapExactInfo) -> u256 {
            let executor = JediRealRouterDispatcher { contract_address: self.router.read() };
            let pair = JediIPairDispatcher { contract_address: swap_info.pool };
            let (supply_0,supply_1,_) = pair.get_reserves();
            if pair.token0() == swap_info.token_in {
                return executor.get_amount_out(swap_info.amount_in_pool, supply_0, supply_1);
            } else {
                return executor.get_amount_out(swap_info.amount_in_pool, supply_1, supply_0);
            }
        }
    }
}

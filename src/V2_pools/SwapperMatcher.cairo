use starknet::ContractAddress;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct MinimalOrderInfoV2Swap {
    maker:ContractAddress,
    quantity: u256,
    price: u256,
    qty_address: ContractAddress,
    price_address: ContractAddress,
}


#[starknet::interface]
trait ISwapperMatcherContract<TContractState> {
    fn match_swap(
        ref self: TContractState,
        order: MinimalOrderInfoV2Swap,
        matching_maker_cost: u256,
        pools: Array<ContractAddress>, market_ids: Array<u16>
    ) -> bool;
    fn get_best_swapper(
        self: @TContractState, swap_info: SwapExactInfo, pools: Array<ContractAddress>, market_ids: Array<u16>
    ) -> (u16, ContractAddress);
}



#[starknet::contract]
mod SwapperMatcherContract {
    use core::traits::TryInto;
use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_contract_address;
    use starknet::info::get_block_timestamp;
    use starknet::info::get_block_number;
    use starknet::contract_address_to_felt252;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use integer::u256_from_felt252;
    use kurosawa_akira::V2_pools::RouterWrapper::AbstractV2Dispatcher;
    use kurosawa_akira::V2_pools::RouterWrapper::AbstractV2DispatcherTrait;
    use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;
    use kurosawa_akira::utils::common::pow_ten;
    use kurosawa_akira::utils::common::get_market_ids_from_tuple;
    use super::MinimalOrderInfoV2Swap;

    #[storage]
    struct Storage {
        v2_address: ContractAddress,
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        v2_address: ContractAddress,
    ) {
        self.v2_address.write(v2_address);
    }

    #[external(v0)]
    impl SwapperMatcherContractImpl of super::ISwapperMatcherContract<ContractState> {
        fn get_best_swapper(
            self: @ContractState, swap_info: SwapExactInfo,
            pools: Array<ContractAddress>, market_ids: Array<u16>
        ) -> (u16,ContractAddress) {
            let mut current_index = 0;
            let last_ind = market_ids.len();
            let mut res = 0;
            let mut best_pool:ContractAddress = 0.try_into().unwrap();
            let mut max_amount_out = 0;
            let mut new_swap_info = swap_info;
            loop {
                if (current_index == last_ind) {
                    break true;
                }
                let market_id: u16 = *market_ids[current_index];
                // let pool:ContractAddress = ;
                new_swap_info.pool = *pools[current_index];
                let amount_out = AbstractV2Dispatcher {contract_address: self.v2_address.read()}.get_amount_out(new_swap_info, market_id);
                if amount_out > max_amount_out {
                    max_amount_out = amount_out;
                    res = market_id;
                    best_pool = new_swap_info.pool;
                }
                current_index += 1;
            };
            return (res, best_pool);
        }
        fn match_swap(
            ref self: ContractState,
            order: MinimalOrderInfoV2Swap,
            matching_maker_cost: u256,
             pools: Array<ContractAddress>, market_ids: Array<u16>
        ) -> bool {
            let mut swap_info = SwapExactInfo {
                amount_in_pool: order.quantity,
                amount_out_min: matching_maker_cost,
                token_in: order.qty_address,
                token_out: order.price_address,
                pool: 0.try_into().unwrap()
            };
            let (best_market, pool) = self.get_best_swapper(swap_info, pools, market_ids);
            
            swap_info.pool = pool;
            let amount_out = AbstractV2Dispatcher { contract_address: self.v2_address.read()}.get_amount_out(swap_info, best_market);
            
            if amount_out > matching_maker_cost {
                AbstractV2Dispatcher { contract_address: self.v2_address.read() }
                    .swap(swap_info, order.maker, best_market);
                return true;
            }
            false
        }
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ababb: ababb
    }

    #[derive(Drop, starknet::Event)]
    struct ababb {}
}

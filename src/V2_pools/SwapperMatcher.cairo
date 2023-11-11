use starknet::ContractAddress;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct MinimalOrderInfoV2Swap {
    maker:ContractAddress,
    quantity: u256,
    price: u256,
    qty_address: ContractAddress,
    price_address: ContractAddress,
    market_ids: (bool, bool),
}


#[starknet::interface]
trait ISwapperMatcherContract<TContractState> {
    fn match_swap(
        ref self: TContractState,
        order: MinimalOrderInfoV2Swap,
        matching_maker_cost: u256,
        pool_address: ContractAddress
    ) -> bool;
    fn get_best_swapper(
        self: @TContractState, swap_info: SwapExactInfo, market_ids: Array<u16>
    ) -> u16;
}



#[starknet::contract]
mod SwapperMatcherContract {
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
            self: @ContractState, swap_info: SwapExactInfo, market_ids: Array<u16>
        ) -> u16 {
            let mut current_index = 0;
            let last_ind = market_ids.len();
            let mut res = 0;
            let mut max_amount_out = 0;
            loop {
                if (current_index == last_ind) {
                    break true;
                }
                let market_id: u16 = *market_ids[current_index];
                let amount_out = AbstractV2Dispatcher {
                    contract_address: self.v2_address.read()
                }
                    .get_amount_out(swap_info, market_id);
                if amount_out > max_amount_out {
                    max_amount_out = amount_out;
                    res = market_id
                }
                current_index += 1;
            };
            res
        }
        fn match_swap(
            ref self: ContractState,
            order: MinimalOrderInfoV2Swap,
            matching_maker_cost: u256,
            pool_address: ContractAddress
        ) -> bool {
            let zero_address = starknet::contract_address_try_from_felt252(0).unwrap();
            let market_ids: Array<u16> = get_market_ids_from_tuple(order.market_ids);
            let swap_info = SwapExactInfo {
                amount_in_pool: order.quantity,
                amount_out_min: matching_maker_cost,
                token_in: order.qty_address,
                token_out: order.price_address,
                pool: zero_address
            };
            let best_market_id = self.get_best_swapper(swap_info, market_ids);
            let amount_out = AbstractV2Dispatcher {
                contract_address: self.v2_address.read()
            }
                .get_amount_out(swap_info, best_market_id);
            if amount_out > matching_maker_cost {
                AbstractV2Dispatcher { contract_address: self.v2_address.read() }
                    .swap(swap_info, order.maker, best_market_id);
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

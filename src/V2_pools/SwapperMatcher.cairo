use starknet::ContractAddress;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct MinimalOrderInfoV2Swap {
    maker: ContractAddress,
    quantity: u256, // refers to qty coin
    overall_matching_volume_cost: u256, // refers to price coin
    qty_address: ContractAddress,
    price_address: ContractAddress,
    is_sell_side: bool
}


//  overallmatching_volume_cost refer to px1*qty1

#[starknet::interface]
trait ISwapperMatcherContract<TContractState> {
    fn match_swap(
        ref self: TContractState,
        order: MinimalOrderInfoV2Swap,
        best_route: u16,
        best_pool: ContractAddress,
        best_amount_receive: u256
    ) -> bool;

    fn get_best_swapper(
        self: @TContractState,
        amount_in: u256,
        token_in: ContractAddress,
        token_out: ContractAddress,
        pools: Array<ContractAddress>,
        market_ids: Array<u16>
    ) -> (u16, ContractAddress, u256);
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
    fn constructor(ref self: ContractState, v2_address: ContractAddress,) {
        self.v2_address.write(v2_address);
    }

    #[external(v0)]
    impl SwapperMatcherContractImpl of super::ISwapperMatcherContract<ContractState> {
        fn get_best_swapper(
            self: @ContractState,
            amount_in: u256,
            token_in: ContractAddress,
            token_out: ContractAddress,
            pools: Array<ContractAddress>,
            market_ids: Array<u16>
        ) -> (u16, ContractAddress, u256) {
            let mut cur_idx = 0;
            if pools.len() != market_ids.len() {
                return (0, 0.try_into().unwrap(), 0);
            }
            if pools.len() == 0 {
                return (0, 0.try_into().unwrap(), 0);
            }
            let mut best_router = 0;
            let mut best_pool: ContractAddress = 0.try_into().unwrap();
            let mut largest_amount = 0;
            let mut swap_info = SwapExactInfo {
                amount_in_pool: amount_in,
                amount_out_min: 0,
                token_in: token_in,
                token_out: token_out,
                pool: best_pool,
            };

            loop {
                let cur_router: u16 = *market_ids[cur_idx];
                swap_info.pool = *pools[cur_idx];
                let amount_out = AbstractV2Dispatcher { contract_address: self.v2_address.read() }
                    .get_amount_out(swap_info, cur_router);
                if amount_out > largest_amount {
                    largest_amount = amount_out;
                    best_pool = swap_info.pool;
                    best_router = cur_router;
                }
                cur_idx += 1;
                if (cur_idx == pools.len()) {
                    break true;
                }
            };
            return (best_router, best_pool, largest_amount);
        }
        fn match_swap(
            ref self: ContractState,
            order: MinimalOrderInfoV2Swap,
            best_route: u16,
            best_pool: ContractAddress,
            best_amount_receive: u256
        ) -> bool {
            if order.is_sell_side {
                if best_amount_receive < order.overall_matching_volume_cost {
                    return false;
                }

                let swap_info = SwapExactInfo {
                    amount_in_pool: order.quantity,
                    amount_out_min: best_amount_receive,
                    token_in: order.qty_address,
                    token_out: order.price_address,
                    pool: best_pool
                };
                // return token_in.into() == 0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8;
                AbstractV2Dispatcher { contract_address: self.v2_address.read() }
                    .swap(swap_info, order.maker, best_route);
                return true;
            } else {
                if best_amount_receive < order.quantity {
                    return false;
                }

                let swap_info = SwapExactInfo {
                    amount_in_pool: order.overall_matching_volume_cost,
                    amount_out_min: best_amount_receive,
                    token_in: order.price_address,
                    token_out: order.qty_address,
                    pool: best_pool
                };
                AbstractV2Dispatcher { contract_address: self.v2_address.read() }
                    .swap(swap_info, order.maker, best_route);
                return true;

            }

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

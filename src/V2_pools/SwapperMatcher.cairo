use starknet::ContractAddress;
use kurosawa_akira::ExchangeEntityStructures::Entities::Order::Order;

#[derive(Copy, Drop, Serde)]
struct SwapExactInfo {
    amount_in_pool: u256,
    amount_out_min: u256,
    token_in: ContractAddress,
    token_out: ContractAddress,
    pool: ContractAddress
}


#[starknet::interface]
trait AbstractV2<T> {
    fn swap(ref self: T, swap_info: SwapExactInfo, recipient: ContractAddress, market_id: u16);

    fn get_amount_out(self: @T, swap_info: SwapExactInfo, market_id: u16) -> u256;

    fn add_router(ref self: T, router: ContractAddress);
}

#[starknet::interface]
trait ISwapperMatcherContract<TContractState> {
    fn match_swap(ref self: TContractState, order: Order, matching_maker_cost: u256) -> bool;
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
    use super::AbstractV2Dispatcher;
    use super::AbstractV2DispatcherTrait;
    use super::SwapExactInfo;
    use kurosawa_akira::ExchangeEntityStructures::Entities::Order::Order;
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;
    use kurosawa_akira::utils::common::pow_ten;
    use kurosawa_akira::utils::common::get_market_ids_from_tuple;

    #[storage]
    struct Storage {
        v2_dispatcher_address: ContractAddress
    }


    #[constructor]
    fn constructor(ref self: ContractState, v2_dispatcher_address: ContractAddress) {
        self.v2_dispatcher_address.write(v2_dispatcher_address);
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
                    contract_address: self.v2_dispatcher_address.read()
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
        fn match_swap(ref self: ContractState, order: Order, matching_maker_cost: u256) -> bool {
            let zero_address = starknet::contract_address_try_from_felt252(0).unwrap();
            let market_ids: Array<u16> = get_market_ids_from_tuple(order.market_ids);
            let qty_decimals = IERC20Dispatcher{contract_address:order.qty_address}.decimals();
            let matching_cost = order.quantity * order.price / pow_ten(qty_decimals);
            let swap_info = SwapExactInfo{
                    amount_in_pool: order.quantity,
                    amount_out_min: matching_cost,
                    token_in: order.qty_address,
                    token_out: order.price_address,
                    pool: zero_address
            };
            let best_market_id = self.get_best_swapper(swap_info, market_ids);
            let amount_out = AbstractV2Dispatcher {
                    contract_address: self.v2_dispatcher_address.read()
                }.get_amount_out(swap_info, best_market_id);
            if amount_out > matching_maker_cost{
                AbstractV2Dispatcher {
                    contract_address: self.v2_dispatcher_address.read()
                }.swap(swap_info, order.maker,best_market_id);
                return true;
            }
            false
        }
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        aba: aba
    }

    #[derive(Drop, starknet::Event)]
    struct aba {}
}

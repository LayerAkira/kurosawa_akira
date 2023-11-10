use serde::Serde;
use starknet::ContractAddress;

#[starknet::interface]
trait ISimpleV2SwapperContract<TContractState> {}

#[starknet::interface]
trait ISimpleV2Swapper<TContractState> {
    fn swap(ref self: TContractState, amount0Out: u256, amount1Out: u256, to: ContractAddress);
}

#[starknet::interface]
trait IExtendedV2Swapper<TContractState> {
    fn swap(
        ref self: TContractState,
        amount0Out: u256,
        amount1Out: u256,
        to: ContractAddress,
        data: Array::<felt252>
    );
}


#[starknet::contract]
mod SimpleV2SwapperContract {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::info::get_block_timestamp;
    use starknet::info::get_block_number;
    use starknet::contract_address_to_felt252;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use super::ISimpleV2SwapperDispatcher;
    use super::ISimpleV2SwapperDispatcherTrait;
    use super::IExtendedV2SwapperDispatcher;
    use super::IExtendedV2SwapperDispatcherTrait;
    use integer::u256_from_felt252;

    #[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
    struct MarketInfo {
        router_id: u256,
        pool: ContractAddress,
    }

    #[storage]
    struct Storage {
        // V2 -- False , V2_EXTRA_DATA -- True
        mkt_id_to_v2: LegacyMap::<u256, bool>,
        mkt_id: u256,
    }


    #[constructor]
    fn constructor(ref self: ContractState) {}

    fn swap_exact_amounts(
        ref self: ContractState,
        amount_in_pool: u256,
        amount_out_pool: u256,
        token_in: ContractAddress,
        token_out: ContractAddress,
        mkt_info: MarketInfo,
        recipient: ContractAddress,
    ) -> u256 {
        assert(mkt_info.router_id < self.mkt_id.read(), 'wrong router id');
        let mkt_type = self.mkt_id_to_v2.read(mkt_info.router_id);
        if mkt_type == false {
            return handle_v2_swap(
                ref self,
                amount_in_pool,
                amount_out_pool,
                token_in,
                token_out,
                mkt_info.pool,
                recipient,
                false
            );
        }
        if mkt_type == true {
            return handle_v2_swap(
                ref self,
                amount_in_pool,
                amount_out_pool,
                token_in,
                token_out,
                mkt_info.pool,
                recipient,
                true
            );
        }
        assert(0 != 0, 'unreachable state');
        0
    }

    fn register_v2_market(ref self: ContractState, v2_type: bool) {
        self.mkt_id_to_v2.write(self.mkt_id.read(), v2_type);
        self.mkt_id.write(self.mkt_id.read() + 1);
    }

    fn handle_v2_swap(
        ref self: ContractState,
        amount_in_pool: u256,
        amount_out_pool: u256,
        token_in: ContractAddress,
        token_out: ContractAddress,
        pool: ContractAddress,
        recipient: ContractAddress,
        extra_data_use: bool
    ) -> u256 {
        IERC20Dispatcher { contract_address: token_in }.transfer(pool, amount_in_pool);
        let balance_before = IERC20Dispatcher { contract_address: token_out }.balanceOf(recipient);
        // sort by token address
        let mut amount0Out: u256 = 0;
        let mut amount1Out: u256 = 0;
        if u256_from_felt252(
            contract_address_to_felt252(token_in)
        ) < u256_from_felt252(contract_address_to_felt252(token_out)) {
            amount1Out = amount_out_pool;
        } else {
            amount0Out = amount_out_pool;
        }
        if extra_data_use {
            let empty_arr = ArrayTrait::<felt252>::new();
            IExtendedV2SwapperDispatcher { contract_address: pool }
                .swap(amount0Out, amount1Out, recipient, empty_arr);
        } else {
            ISimpleV2SwapperDispatcher { contract_address: pool }
                .swap(amount0Out, amount1Out, recipient);
        }
        let balance_after = IERC20Dispatcher { contract_address: token_out }.balanceOf(recipient);
        let delta = balance_after - balance_before;
        delta
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}
}

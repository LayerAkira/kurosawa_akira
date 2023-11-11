use serde::Serde;
use starknet::ContractAddress;
use starknet::contract_address_to_felt252;
use array::ArrayTrait;

use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapper;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;

use debug::PrintTrait;

use kurosawa_akira::V2_pools::RouterWrapper::AbstractV2Dispatcher;
use kurosawa_akira::V2_pools::RouterWrapper::AbstractV2DispatcherTrait;
use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapperDispatcher;
use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapperDispatcherTrait;
use kurosawa_akira::V2_pools::RouterWrapper::ConcreteV2;


#[cfg(test)]
mod tests {
    use core::traits::Into;
    use core::array::ArrayTrait;
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use core::result::ResultTrait;
    use snforge_std::declare;
    use starknet::ContractAddress;
    use snforge_std::ContractClassTrait;
    use super::RouterWrapperDispatcher;
    use super::RouterWrapperDispatcherTrait;

    use super::AbstractV2Dispatcher;
    use super::AbstractV2DispatcherTrait;
    use super::SwapExactInfo;

    use starknet::info::get_block_number;
    use debug::PrintTrait;
    use starknet::get_caller_address;

    use snforge_std::start_prank;
    use snforge_std::stop_prank;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use kurosawa_akira::V2_pools::RouterWrapper::ConcreteV2;
    use kurosawa_akira::V2_pools::SwapperMatcher::ISwapperMatcherContract;
    use kurosawa_akira::V2_pools::SwapperMatcher::ISwapperMatcherContractDispatcher;
    use kurosawa_akira::V2_pools::SwapperMatcher::ISwapperMatcherContractDispatcherTrait;
    use kurosawa_akira::V2_pools::SwapperMatcher::MinimalOrderInfoV2Swap;
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};

    fn get_jedi_swap(router_address: ContractAddress) -> ContractAddress {
        let cls = declare('JediWrapper');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(router_address.into());
        let deployed = cls.deploy(@constructor).unwrap();
        let dummy_wrapper = RouterWrapperDispatcher { contract_address: deployed };
        return deployed;
    }

    fn get_10k_swap(router_address: ContractAddress) -> ContractAddress {
        let dummy_wrapper_cls = declare('TenKWrapper');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(router_address.into());
        let deployed = dummy_wrapper_cls.deploy(@constructor).unwrap();
        let dummy_wrapper = RouterWrapperDispatcher { contract_address: deployed };
        return deployed;
    }

    fn get_sith_swap() -> ContractAddress {
        let dummy_wrapper_cls = declare('SithWrapper');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        let deployed = dummy_wrapper_cls.deploy(@constructor).unwrap();
        let dummy_wrapper = RouterWrapperDispatcher { contract_address: deployed };
        return deployed;
    }


    fn test_get_reserves(adapter: AbstractV2Dispatcher, info: SwapExactInfo, mkt_id: u16) -> u256 {
        return adapter.get_amount_out(info, mkt_id);
    }

    fn test_swap(adapter: AbstractV2Dispatcher, info: SwapExactInfo, mkt_id: u16) {
        //#myswap actually
        let caller_who_have_funds: ContractAddress =
            0x00000005dd3d2f4429af886cd1a3b08289dbcea99a294197e9eb43b0e0325b4b
            .try_into()
            .unwrap();
        let erc20 = IERC20Dispatcher { contract_address: info.token_in };

        start_prank(erc20.contract_address, caller_who_have_funds);

        erc20.approve(adapter.contract_address, info.amount_in_pool);
        stop_prank(info.token_in);

        start_prank(adapter.contract_address, caller_who_have_funds);
        let received_erc20 = IERC20Dispatcher { contract_address: info.token_out };
        let receiver: ContractAddress = 1.try_into().unwrap();

        let balance_before = received_erc20.balanceOf(receiver);

        adapter.swap(info, receiver, mkt_id);
        let balance_after = received_erc20.balanceOf(receiver);
        received_erc20.balanceOf(receiver).print();

        assert(info.amount_out_min == balance_after - balance_before, 'wrong trade');
    }

    fn get_test_data(trade_amount: u256, pool_addr: ContractAddress) -> SwapExactInfo {
        let usdc_token: ContractAddress =
            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            .try_into()
            .unwrap();
        let usdt_token: ContractAddress =
            0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
            .try_into()
            .unwrap();
        return SwapExactInfo {
            amount_in_pool: trade_amount,
            amount_out_min: 0,
            token_in: usdc_token,
            token_out: usdt_token,
            pool: pool_addr,
        };
    }

    fn init_adapter() -> AbstractV2Dispatcher {
        let contract = declare('ConcreteV2');
        let contract_address = contract.deploy(@ArrayTrait::new()).unwrap();

        // Create a Dispatcher object that will allow interacting with the deployed contract
        let adapter = AbstractV2Dispatcher { contract_address: contract_address };

        let mainnet_jedi_swap_router_addr: ContractAddress =
            0x041fd22b238fa21cfcf5dd45a8548974d8263b3a531a60388411c5e230f97023
            .try_into()
            .unwrap();
        let mainnet_10k_swap_router_addr: ContractAddress =
            0x07a6f98c03379b9513ca84cca1373ff452a7462a3b61598f0af5bb27ad7f76d1
            .try_into()
            .unwrap();
        // add jedi wrapper at index 1
        let jedi_wrapper = get_jedi_swap(mainnet_jedi_swap_router_addr);
        // add 10kSwap  at index 2
        let ten_k_swap = get_10k_swap(mainnet_10k_swap_router_addr);
        // addd sith at index 3
        let sith_swap = get_sith_swap();

        adapter.add_router(jedi_wrapper);
        adapter.add_router(ten_k_swap);
        adapter.add_router(sith_swap);
        return adapter;
    }

    #[test]
    #[available_gas(10000000000)]
    #[fork("forked")]
    fn test_jedi() {
        let adapter = init_adapter();

        let jedi_pool: ContractAddress =
            0x05801bdad32f343035fb242e98d1e9371ae85bc1543962fedea16c59b35bd19b
            .try_into()
            .unwrap();
        let mut info = get_test_data(100_000, jedi_pool);
        info.amount_out_min = test_get_reserves(adapter, info, 1);
        test_swap(adapter, info, 1);
    }

    #[test]
    #[available_gas(10000000000)]
    #[fork("forked")]
    fn test_10k_swap() {
        let adapter = init_adapter();
        let ten_k_pool: ContractAddress =
            0x041a708cf109737a50baa6cbeb9adf0bf8d97112dc6cc80c7a458cbad35328b0
            .try_into()
            .unwrap();
        let mut info = get_test_data(100_000, ten_k_pool);
        info.amount_out_min = test_get_reserves(adapter, info, 2);
        test_swap(adapter, info, 2);
    }

    #[test]
    #[available_gas(10000000000)]
    #[fork("forked")]
    fn test_joint() {
        let adapter = init_adapter();

        let jedi_pool: ContractAddress =
            0x05801bdad32f343035fb242e98d1e9371ae85bc1543962fedea16c59b35bd19b
            .try_into()
            .unwrap();
        let mut info = get_test_data(100_000, jedi_pool);
        info.amount_out_min = test_get_reserves(adapter, info, 1);
        test_swap(adapter, info, 1);

        let ten_k_pool: ContractAddress =
            0x041a708cf109737a50baa6cbeb9adf0bf8d97112dc6cc80c7a458cbad35328b0
            .try_into()
            .unwrap();
        let mut info = get_test_data(100_000, ten_k_pool);
        info.amount_out_min = test_get_reserves(adapter, info, 2);
        test_swap(adapter, info, 2);

        let sith_pool: ContractAddress =
            0x0601f72228f73704e827de5bcd8dadaad52c652bb1e42bf492d90bbe22df2cec
            .try_into()
            .unwrap();
        let mut info = get_test_data(100_000, sith_pool);
        info.amount_out_min = test_get_reserves(adapter, info, 3);
        test_swap(adapter, info, 3);
    }

    #[test]
    #[available_gas(10000000000)]
    #[fork("forked")]
    fn test_sith_swap() {
        let adapter = init_adapter();
        let sith_pool: ContractAddress =
            0x0601f72228f73704e827de5bcd8dadaad52c652bb1e42bf492d90bbe22df2cec
            .try_into()
            .unwrap();
        let mut info = get_test_data(100_000, sith_pool);
        info.amount_out_min = test_get_reserves(adapter, info, 3);
        test_swap(adapter, info, 3);
    }

    fn init_matcher(adapter: ContractAddress) -> ISwapperMatcherContractDispatcher {
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(adapter.into());
        let contract = declare('SwapperMatcherContract');
        let contract_address = contract.deploy(@constructor).unwrap();
        let matcher = ISwapperMatcherContractDispatcher { contract_address: contract_address };
        return matcher;
    }


    fn init_ctx_matcher() -> (
        AbstractV2Dispatcher, ISwapperMatcherContractDispatcher, Array<u16>, Array<ContractAddress>
    ) {
        let adapter = init_adapter();
        let matcher = init_matcher(adapter.contract_address);

        let jedi_pool: ContractAddress =
            0x05801bdad32f343035fb242e98d1e9371ae85bc1543962fedea16c59b35bd19b
            .try_into()
            .unwrap();
        let sith_pool: ContractAddress =
            0x0601f72228f73704e827de5bcd8dadaad52c652bb1e42bf492d90bbe22df2cec
            .try_into()
            .unwrap();

        let mut pools: Array::<ContractAddress> = ArrayTrait::new();
        pools.append(sith_pool);

        pools.append(jedi_pool);

        let mut mkts: Array::<u16> = ArrayTrait::new();
        mkts.append(3);
        mkts.append(1);

        return (adapter, matcher, mkts, pools);
    }

    #[test]
    #[available_gas(10000000000)]
    #[fork("forked")]
    fn test_matcher_get_best_route() {
        let (adapter, matcher, mkts, pools) = init_ctx_matcher();
        let pool_amount_in: u256 = 10_000_000;

        let usdc_token: ContractAddress =
            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            .try_into()
            .unwrap();
        let usdt_token: ContractAddress =
            0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
            .try_into()
            .unwrap();

        let (router, pool, amount) = matcher
            .get_best_swapper(pool_amount_in, usdc_token, usdt_token, pools, mkts);
        router.print();
    }

    fn test_swap_matcher(pool_amount_in: u256, would_be_traded_clob: u256, is_sell_side: bool) {
        let receiver: ContractAddress = 1.try_into().unwrap();

        let (adapter, matcher, mkts, pools) = init_ctx_matcher();
        let usdc_token: ContractAddress =
            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            .try_into()
            .unwrap();
        let usdt_token: ContractAddress =
            0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
            .try_into()
            .unwrap();

        let caller_who_have_funds: ContractAddress =
            0x00000005dd3d2f4429af886cd1a3b08289dbcea99a294197e9eb43b0e0325b4b
            .try_into()
            .unwrap();

        if is_sell_side {
            //  ticker usdc/usdt, we selling  pool_amount_in usdt and getting would_be_traded_clob usdc
            let (router, pool, amount) = matcher
                .get_best_swapper(pool_amount_in, usdt_token, usdc_token, pools, mkts);
            let order_info = MinimalOrderInfoV2Swap {
                maker: receiver,
                quantity: pool_amount_in, //usdc
                overall_matching_volume_cost: would_be_traded_clob,
                qty_address: usdt_token,
                price_address: usdc_token,
                is_sell_side: true
            };
            let erc20 = IERC20Dispatcher { contract_address: usdt_token };
            start_prank(erc20.contract_address, caller_who_have_funds);
            erc20.transfer(matcher.contract_address, pool_amount_in);
            stop_prank(erc20.contract_address);

            start_prank(erc20.contract_address, matcher.contract_address);
            erc20.approve(adapter.contract_address, pool_amount_in);
            stop_prank(erc20.contract_address);

            let erc20 = IERC20Dispatcher { contract_address: usdc_token };
            let balance_before = erc20.balanceOf(receiver);

            assert(
                matcher.match_swap(order_info, router, pool, amount) == true,
                'Wrong, match should happen'
            );

            let balance_after = erc20.balanceOf(receiver);
            assert(amount == balance_after - balance_before, 'wrong trade');
        } else {
            //  ticker usdc/usdt, we are selling usdc  pool_amount_in and get would_be_traded_clob usdt
            let (router, pool, amount) = matcher
                .get_best_swapper(pool_amount_in, usdc_token, usdt_token, pools, mkts);
            let order_info = MinimalOrderInfoV2Swap {
                maker: receiver,
                quantity: would_be_traded_clob, //usdc
                overall_matching_volume_cost: pool_amount_in,
                qty_address: usdt_token,
                price_address: usdc_token,
                is_sell_side: false
            };
            let erc20 = IERC20Dispatcher { contract_address: usdc_token };
            start_prank(erc20.contract_address, caller_who_have_funds);
            erc20.transfer(matcher.contract_address, pool_amount_in);
            stop_prank(erc20.contract_address);

            start_prank(erc20.contract_address, matcher.contract_address);
            erc20.approve(adapter.contract_address, pool_amount_in);
            stop_prank(erc20.contract_address);

            let erc20 = IERC20Dispatcher { contract_address: usdt_token };
            let balance_before = erc20.balanceOf(receiver);

            assert(
                matcher.match_swap(order_info, router, pool, amount) == true,
                'Wrong, match should happen'
            );

            let balance_after = erc20.balanceOf(receiver);
            assert(amount == balance_after - balance_before, 'wrong trade');
        }
    }

    #[test]
    #[available_gas(10000000000)]
    #[fork("forked")]
    fn test_matcher_swap_sell_order() {
        test_swap_matcher(10_000_001, 9_000_000, true);
    }

    #[test]
    #[available_gas(10000000000)]
    #[fork("forked")]
    fn test_matcher_swap_buy_order() {
        test_swap_matcher(10_000_001, 9_000_000, false);
    }
}

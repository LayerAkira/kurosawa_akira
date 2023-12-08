#[cfg(test)]
mod tests_deposit_and_withdrawal {
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to,get_fee_recipient_exchange,get_slow_mode,get_trader_address_1,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native};
    use kurosawa_akira::FundsTraits::PoseidonHash;
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_prank,start_warp,stop_warp,stop_prank,declare,ContractClassTrait, start_roll, stop_roll};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::LayerAkira::LayerAkira;
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::ILayerAkira::{ILayerAkiraDispatcher, ILayerAkiraDispatcherTrait};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};


    #[test]
    #[fork("block_based")]
    fn test_eth_deposit() {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, 2 * amount_deposit);
        deposit(trader, amount_deposit, eth_addr, akira); 
        deposit(trader, amount_deposit, eth_addr, akira); 
    }



    fn request_onchain_withdraw(trader:ContractAddress, amount:u256, token:ContractAddress, akira:ILayerAkiraDispatcher, salt:felt252)-> (Withdraw,SlowModeDelay) {
        let gas_fee = prepare_double_gas_fee_native(akira,100);
        let amount = if token == akira.get_wrapped_native_token() { amount - gas_fee.gas_per_action.into() * gas_fee.max_gas_price} else {amount};
        let withdraw = Withdraw {maker:trader, token, amount, salt, gas_fee, reciever:trader};
        start_prank(akira.contract_address, trader); akira.request_onchain_withdraw(withdraw); stop_prank(akira.contract_address);
        let (request_time,w) = akira.get_pending_withdraw(trader, token);
        assert(withdraw == w, 'WRONG_WTIHDRAW_RETURNED');
        return (withdraw, request_time);
    }

    fn withdraw_direct(trader:ContractAddress,token:ContractAddress, akira:ILayerAkiraDispatcher, use_delay:bool) {
        let delay = get_slow_mode();
        let(req_time, w) = akira.get_pending_withdraw(trader,token);
        let erc = IERC20Dispatcher{contract_address:token};
        let balance_trader = erc.balanceOf(trader);
        let (akira_total, akira_user) = (akira.total_supply(token), akira.balanceOf(trader,token));

        if use_delay{
            start_roll(akira.contract_address, delay.block + req_time.block); 
            start_warp(akira.contract_address, req_time.ts + delay.ts);
        }
        start_prank(akira.contract_address, trader); akira.apply_onchain_withdraw(token, w.get_poseidon_hash()); stop_prank(akira.contract_address);
        if use_delay {
             stop_roll(akira.contract_address);
             stop_warp(akira.contract_address);
        }

        assert(erc.balanceOf(trader) - balance_trader == w.amount, 'WRONG_AMOUNT_RECEIVED');
        assert(akira_total - akira.total_supply(token) == w.amount, 'WRONG_BURN_TOTAL');
        assert(akira_user - akira.balanceOf(trader, token) == w.amount, 'WRONG_BURN_TOKEN');
    }

    #[test]
    #[fork("block_based")]
    #[should_panic(expected: ('FEW_TIME_PASSED',))]
    fn test_withdraw_eth_direct_immediate() {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, amount_deposit);
        deposit(trader, amount_deposit, eth_addr, akira); 
        request_onchain_withdraw(trader, amount_deposit, eth_addr, akira, 0);
        withdraw_direct(trader,eth_addr,akira,false);
    }

    #[test]
    #[fork("block_based")]
    fn test_withdraw_eth_direct_delayed() {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, amount_deposit);
        deposit(trader, amount_deposit, eth_addr, akira); 
        request_onchain_withdraw(trader, amount_deposit, eth_addr, akira, 0);
        withdraw_direct(trader, eth_addr, akira, true);     
    }

    #[test]
    #[fork("block_based")]
    #[should_panic(expected: ('WRONG_MAKER',))]
    fn test_withdraw_eth_direct_delayed_cant_apply_twice() {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, amount_deposit);
        deposit(trader, amount_deposit, eth_addr, akira); 
        request_onchain_withdraw(trader, amount_deposit, eth_addr, akira, 0);
        withdraw_direct(trader, eth_addr, akira, true);     
        withdraw_direct(trader, eth_addr, akira, true);     
    }

    #[test]
    #[fork("block_based")]
    fn test_withdraw_eth_direct_no_delayed_by_exchange() {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (trader, eth_addr, amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, amount_deposit); deposit(trader, amount_deposit, eth_addr, akira); 
        let(withdraw, _) = request_onchain_withdraw(trader, amount_deposit, eth_addr, akira, 0);
        start_prank(akira.contract_address, get_fee_recipient_exchange());
        akira.apply_withdraw(SignedWithdraw{withdraw, sign:(0.into(), 0.into())}, 100);
        stop_prank(akira.contract_address);
    }
    //     #[test]
    // #[fork("block_based")]
    // fn test_withdraw_eth_direct_no_delayed_by_exchange() {
        // TODO via sign stuff?
    // }    
}


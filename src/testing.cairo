#[cfg(test)]
mod tests_deposit_and_withdrawal {
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to,get_fee_recipient_exchange,get_slow_mode,get_trader_address_1,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,get_trader_signer_and_pk_1,sign};
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
    use kurosawa_akira::FundsTraits::check_sign;
    
    
    #[test]
    #[fork("block_based")]
    fn test_eth_deposit() {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, 2 * amount_deposit);
        deposit(trader, amount_deposit, eth_addr, akira); 
        deposit(trader, amount_deposit, eth_addr, akira); 
    }

    fn get_withdraw(trader:ContractAddress, amount:u256, token:ContractAddress, akira:ILayerAkiraDispatcher, salt:felt252)-> Withdraw {
        let gas_fee = prepare_double_gas_fee_native(akira,100);
        let amount = if token == akira.get_wrapped_native_token() { amount - gas_fee.gas_per_action.into() * gas_fee.max_gas_price} else {amount};
        return Withdraw {maker:trader, token, amount, salt, gas_fee, reciever:trader};
        
    }

    fn request_onchain_withdraw(trader:ContractAddress, amount:u256, token:ContractAddress, akira:ILayerAkiraDispatcher, salt:felt252)-> (Withdraw,SlowModeDelay) {
        let withdraw = get_withdraw(trader,amount,token,akira,salt);
        start_prank(akira.contract_address, trader); akira.request_onchain_withdraw(withdraw); stop_prank(akira.contract_address);
        let (request_time, w) = akira.get_pending_withdraw(trader, token);
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
    #[test]
    #[fork("block_based")]
    fn test_withdraw_eth_indirect() {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (trader, eth_addr, amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        let (pub,priv) = get_trader_signer_and_pk_1();
        
        tfer_eth_funds_to(trader, amount_deposit); deposit(trader, amount_deposit, eth_addr, akira); 
        
        let w = get_withdraw(trader, amount_deposit, eth_addr, akira, 0);

        start_prank(akira.contract_address, trader); akira.bind_to_signer(pub.try_into().unwrap()); stop_prank(akira.contract_address); 
       
        start_prank(akira.contract_address, get_fee_recipient_exchange());
        akira.apply_withdraw(SignedWithdraw{withdraw:w, sign: sign(w.get_poseidon_hash(), pub, priv)}, 100);
        stop_prank(akira.contract_address);
    }    

    #[test]
    #[fork("block_based")]
    #[should_panic(expected: ('ALREADY_APPLIED',))]
    fn test_withdraw_eth_indirect_twice() {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (trader, eth_addr, amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        let (pub,priv) = get_trader_signer_and_pk_1();
        
        tfer_eth_funds_to(trader, amount_deposit); deposit(trader, amount_deposit, eth_addr, akira); 
        
        let w = get_withdraw(trader, amount_deposit, eth_addr, akira, 0);

        start_prank(akira.contract_address, trader); akira.bind_to_signer(pub.try_into().unwrap()); stop_prank(akira.contract_address); 

        start_prank(akira.contract_address, get_fee_recipient_exchange());
        let sign = sign(w.get_poseidon_hash(), pub, priv);
        akira.apply_withdraw(SignedWithdraw{withdraw:w, sign}, 100);
        akira.apply_withdraw(SignedWithdraw{withdraw:w, sign}, 100);
        
        stop_prank(akira.contract_address);
    }  
}

mod test_common_trade {

    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to,get_fee_recipient_exchange,get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,sign,get_trader_signer_and_pk_2};
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
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};


    fn prepare() ->(ILayerAkiraDispatcher, ContractAddress, ContractAddress, ContractAddress, ContractAddress, u256, u256) {
        let akira = ILayerAkiraDispatcher{contract_address:spawn_exchange()};
        let (tr1,tr2, (pub1, pk1), (pub2, pk2)) = (get_trader_address_1(), get_trader_address_2(), get_trader_signer_and_pk_1(), get_trader_signer_and_pk_2());
        let (eth, usdc) = (get_eth_addr(), get_usdc_addr());
        let (eth_amount, usdc_amount) = (1_000_000_000_000_000_000, 2000_000_000); //1eth and 2k usdc 
        tfer_eth_funds_to(tr1, 2 * eth_amount); tfer_eth_funds_to(tr2, 2 * eth_amount);
        tfer_usdc_funds_to(tr1, 2 *  usdc_amount); tfer_usdc_funds_to(tr2, 2 * usdc_amount);

        start_prank(akira.contract_address, tr1); akira.bind_to_signer(pub1.try_into().unwrap()); stop_prank(akira.contract_address); 
        start_prank(akira.contract_address, tr2); akira.bind_to_signer(pub2.try_into().unwrap()); stop_prank(akira.contract_address); 
        
        return (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount);
    }

    fn get_maker_taker_fees()->(u32, u32)  {  (100, 200)} //1 and 2 bips

    fn get_swap_gas_cost()->u32 {100}

    fn get_zero_router_fee() -> FixedFee {
        FixedFee{recipient:0.try_into().unwrap(), maker_pbips:0, taker_pbips: 0}
    }

    fn zero_router() -> ContractAddress { 0.try_into().unwrap()}


    fn spawn_order(akira:ILayerAkiraDispatcher, maker:ContractAddress, price:u256, quantity:u256,
            flags:OrderFlags,
            num_swaps_allowed:u8, router_signer:ContractAddress) ->SignedOrder {
        let zero_addr:ContractAddress = 0.try_into().unwrap();
        let ticker =(get_eth_addr(), get_usdc_addr()); 
        let salt = num_swaps_allowed.into();
        let (maker_pbips,taker_pbips) = get_maker_taker_fees();
        let fee_recipient = akira.get_fee_recipient();
        let router_fee =  if router_signer != zero_addr { 
            FixedFee{recipient:akira.get_router(router_signer), maker_pbips, taker_pbips}
        } else { FixedFee{recipient: zero_addr, maker_pbips:0, taker_pbips:0}
        };
        let mut order = Order {
            maker, price, quantity, ticker, number_of_swaps_allowed:num_swaps_allowed, salt, router_signer,
            base_asset: 1_000_000_000_000_000_000, nonce:akira.get_nonce(maker),
            fee: OrderFee {
                trade_fee:  FixedFee{recipient:fee_recipient, maker_pbips, taker_pbips},
                router_fee: router_fee,
                gas_fee: prepare_double_gas_fee_native(akira, get_swap_gas_cost())
            },
            flags
        };
        let hash = order.get_poseidon_hash();
        let (pub, pk) = if maker == get_trader_address_1() {
            get_trader_signer_and_pk_1()
        } else  { get_trader_signer_and_pk_2()};
  
        return SignedOrder{order, sign:sign(hash, pub, pk), router_sign:(0,0)};
    }

    fn register_router(akira:ILayerAkiraDispatcher, funds_account:ContractAddress, signer:ContractAddress, router_address:ContractAddress) {
        let (route_amount, base) = (akira.get_route_amount(), akira.get_wrapped_native_token());
        
        start_prank(base, funds_account);
        IERC20Dispatcher{contract_address:base}.increaseAllowance(akira.contract_address,  route_amount);
        stop_prank(base);
        
        start_prank(akira.contract_address, funds_account);
        akira.router_deposit(router_address, base, route_amount);
        stop_prank(akira.contract_address);
        
        
        start_prank(akira.contract_address, router_address);
        akira.register_router();
        
        akira.add_router_binding(signer);

        stop_prank(akira.contract_address);
        
    }

}

#[cfg(test)]
mod tests_safe_trade {
    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to,get_fee_recipient_exchange,get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,sign,get_trader_signer_and_pk_2};
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
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};


    use super::test_common_trade:: {prepare,get_maker_taker_fees,get_swap_gas_cost,spawn_order, get_zero_router_fee,zero_router};



    fn get_order_flags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_safe_book: true};
    }

    #[test]
    #[fork("block_based")]
    fn test_succ_match_single_buy_taker_trade_full() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let mut taker_orders: Array<SignedOrder>  = ArrayTrait::new();
        let mut maker_orders: Array<SignedOrder>  = ArrayTrait::new();
        let mut iters: Array<(u8,bool)> = ArrayTrait::new();

        deposit(tr1, eth_amount, eth, akira);
        deposit(tr2, usdc_amount, usdc, akira);


        let sell_limit_flags = get_order_flags(false,false,true,true,false);
        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, sell_limit_flags, 0, zero_router());

        let buy_limit_flags = get_order_flags(false, false, false, false, true);

        iters.append((1, false));
        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, buy_limit_flags, 2, zero_router());
        start_prank(akira.contract_address, get_fee_recipient_exchange());

        taker_orders.append(buy_order);
        maker_orders.append(sell_order);

        akira.apply_safe_trade(taker_orders, maker_orders, iters, 100);

        let maker_fee = get_feeable_qty(sell_order.order.fee.trade_fee, usdc_amount, true);
        assert(akira.balanceOf(sell_order.order.maker, usdc) == usdc_amount - maker_fee,'WRONG_MATCH_RECIEVE_USDC');
        assert(akira.balanceOf(buy_order.order.maker, usdc) == 0,'WRONG_MATCH_SEND_USDC');
                
        let taker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, eth_amount, false);
        let gas_fee = 100 * get_swap_gas_cost().into();
        assert(akira.balanceOf(buy_order.order.maker, eth) == eth_amount - gas_fee - taker_fee, 'WRONG_MATCH_RECIEVE_ETH');
        assert(akira.balanceOf(sell_order.order.maker, eth) == 0, 'WRONG_MATCH_SEND_ETH');
       
        
        stop_prank(akira.contract_address);
    }  



    #[test]
    #[fork("block_based")]
    fn test_succ_match_single_sell_taker_trade_full() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let mut taker_orders: Array<SignedOrder>  = ArrayTrait::new();
        let mut maker_orders: Array<SignedOrder>  = ArrayTrait::new();
        let mut iters: Array<(u8,bool)> = ArrayTrait::new();

        let gas_required:u256 = 100 * get_swap_gas_cost().into(); 

        deposit(tr1, eth_amount, eth, akira); deposit(tr2, usdc_amount, usdc, akira);

        let sell_market_flags = get_order_flags(false, false, false, true, true);
        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount - gas_required, sell_market_flags, 2, zero_router());

        let buy_limit_flags = get_order_flags(false, false, true, false, false);

        iters.append((1, false));
        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, buy_limit_flags, 0,  zero_router());
        start_prank(akira.contract_address, get_fee_recipient_exchange());

        taker_orders.append(sell_order);
        maker_orders.append(buy_order);

        let t1 = taker_orders.clone();
        let t2 = maker_orders.clone();
        let i = iters.clone();


        akira.apply_safe_trade(taker_orders, maker_orders, iters, 100);

        //0 cause remaining eth was spent on gas
        assert(akira.balanceOf(sell_order.order.maker, eth) == 0,'WRONG_MATCH_ETH_SELL');
        stop_prank(akira.contract_address);
    }  



}

#[cfg(test)]
mod tests_unsafe_trade {
    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to, get_fee_recipient_exchange, get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,sign,get_trader_signer_and_pk_2};
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
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};


    use super::test_common_trade:: {prepare, get_maker_taker_fees, get_swap_gas_cost,spawn_order, get_zero_router_fee, zero_router,register_router};
    
    fn grant_allowances(akira:ILayerAkiraDispatcher,trader:ContractAddress,token:ContractAddress, amount:u256) {
        start_prank(token, trader);
        IERC20Dispatcher{contract_address:token}.increaseAllowance(akira.contract_address,amount);
        stop_prank(token);
    }

    fn get_order_flags(full_fill_only:bool, best_level_only:bool, post_only:bool, is_sell_side:bool, is_market_order:bool) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_safe_book: false};
    }

    #[test]
    #[should_panic(expected: ('NOT_REGISTERED',))]
    #[fork("block_based")]
    fn test_cant_execute_with_not_registered_router() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let mut maker_orders: Array<SignedOrder>  = ArrayTrait::new();

        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, true, false), 0, zero_router());
        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, false, true), 2, zero_router());
        
        maker_orders.append(sell_order);

        start_prank(akira.contract_address, get_fee_recipient_exchange());
        akira.apply_unsafe_trade(buy_order, maker_orders, usdc_amount*eth_amount / buy_order.order.base_asset, 100);
        stop_prank(akira.contract_address);
    }  



    #[test]
    #[fork("block_based")]
    fn test_execute_with_buy_taker_succ() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let mut maker_orders: Array<SignedOrder>  = ArrayTrait::new();
        let router:ContractAddress = 1.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer:ContractAddress = signer.try_into().unwrap();
        
        deposit(tr1, eth_amount, eth, akira);

        
        register_router(akira, tr1, signer, router);

        let gas_fee = 100 * get_swap_gas_cost().into();
        
        // grant necesasry allowances 
        grant_allowances(akira, tr2, eth, gas_fee);
        grant_allowances(akira, tr2, usdc, usdc_amount+100000000);

        let mut buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, false, true), 2, signer);

        buy_order.router_sign = sign(buy_order.order.get_poseidon_hash(), signer.into(), signer_pk);

        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, true, false), 0, zero_router());
        
        maker_orders.append(sell_order);


        let eth_erc = IERC20Dispatcher{contract_address:eth};
        let usdc_erc = IERC20Dispatcher{contract_address:usdc};
        let taker = buy_order.order.maker;

        let (eth_b, usdc_b, router_b) = (eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker), akira.balance_of_router(router, eth));



        start_prank(akira.contract_address, get_fee_recipient_exchange());
        assert(akira.apply_unsafe_trade(buy_order, maker_orders,  (1+usdc_amount) * eth_amount / buy_order.order.base_asset, 100), 'FAILED_MATCH');
        stop_prank(akira.contract_address);



        let maker_fee = get_feeable_qty(sell_order.order.fee.trade_fee, usdc_amount, true);
        
        assert(akira.balanceOf(sell_order.order.maker, usdc) == usdc_amount - maker_fee, 'WRONG_MATCH_RECIEVE_USDC');
        
        assert(akira.balanceOf(buy_order.order.maker, usdc) == 0,'WRONG_MATCH_SEND_USDC');
                
        let taker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, eth_amount, false);
        let router_fee = get_feeable_qty(buy_order.order.fee.router_fee, eth_amount, false);
        
        assert(akira.balanceOf(sell_order.order.maker, eth) == 0, 'WRONG_MATCH_SEND_ETH');
       
        assert(akira.balanceOf(buy_order.order.maker, eth) == 0, 'WRONG_UNSAFE_BALANCE_ETH');
        assert(akira.balanceOf(buy_order.order.maker, usdc) == 0, 'WRONG_UNSAFE_BALANCE_USDC');

        let (eth_b, usdc_b) = (eth_erc.balanceOf(taker) - eth_b, usdc_b - usdc_erc.balanceOf(taker));
        assert(usdc_b == usdc_amount, 'DEDUCTED_AS_EXPECTED');
        assert(eth_b + gas_fee  + taker_fee + router_fee == eth_amount, 'RECEIVED_AS_EXPECTED');
        assert(akira.balance_of_router(router, eth) - router_b == router_fee, 'WRONG_ROUTER_RECEIVED');
        
    } 

    #[test]
    #[fork("block_based")]
    fn test_execute_with_sell_taker_succ() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let mut maker_orders: Array<SignedOrder>  = ArrayTrait::new();
        let router: ContractAddress = 1.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer: ContractAddress = signer.try_into().unwrap();
        register_router(akira, tr1, signer, router);
        
        deposit(tr1, usdc_amount, usdc, akira);
        let gas_fee = 100 * get_swap_gas_cost().into();
        
        grant_allowances(akira, tr2, eth, gas_fee + eth_amount+10000000);
        
        let mut sell_order = spawn_order(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, true, true), 1, signer);
        sell_order.router_sign = sign(sell_order.order.get_poseidon_hash(), signer.into(), signer_pk);


        let buy_order = spawn_order(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, false, false), 0, zero_router());
        maker_orders.append(buy_order);


        let eth_erc = IERC20Dispatcher{contract_address:eth};
        let usdc_erc = IERC20Dispatcher{contract_address:usdc};
        let taker = sell_order.order.maker;
        let (eth_b, usdc_b, router_b) = (eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker), akira.balance_of_router(router, usdc));

        start_prank(akira.contract_address, get_fee_recipient_exchange());
        assert(akira.apply_unsafe_trade(sell_order, maker_orders,  eth_amount+10000000, 100), 'FAILED_MATCH');
        stop_prank(akira.contract_address);
         
        assert(akira.balanceOf(sell_order.order.maker, eth) == 0, 'WRONG_UNSAFE_BALANCE_ETH');
        assert(akira.balanceOf(sell_order.order.maker, usdc) == 0, 'WRONG_UNSAFE_BALANCE_USDC');
        let taker_fee = get_feeable_qty(sell_order.order.fee.trade_fee, usdc_amount, false);
        let router_fee = get_feeable_qty(sell_order.order.fee.router_fee, usdc_amount, false);
        assert(akira.balance_of_router(router, usdc) - router_b == router_fee, 'WRONG_ROUTER_RECEIVED');

        let maker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, eth_amount, true);
        assert(akira.balanceOf(buy_order.order.maker, eth) == eth_amount - maker_fee, 'WRONG_MATCH_RECIEVE_ETH');
        assert(akira.balanceOf(buy_order.order.maker, usdc) == 0, 'WRONG_SEND_USDC');


        let (eth_b, usdc_b) = (eth_b - eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker) - usdc_b);
        assert(usdc_b + taker_fee + router_fee == usdc_amount, 'RECEIVED_AS_EXPECTED');

        assert(eth_b - gas_fee == eth_amount, 'DEDUCTED_AS_EXPECTED');



        start_prank(akira.contract_address, router);
        akira.router_withdraw(usdc, router_fee, router);
        assert(usdc_erc.balanceOf(router) == router_fee, 'WRONG_ROUTER_WITHDRAW');
        stop_prank(akira.contract_address);

        
    }  


    #[test]
    #[fork("block_based")]
    fn test_punish_router() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let mut maker_orders: Array<SignedOrder>  = ArrayTrait::new();
        let router:ContractAddress = 1.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer:ContractAddress = signer.try_into().unwrap();
        
        deposit(tr1, eth_amount, eth, akira);
        register_router(akira, tr1, signer, router);
        let gas_fee = 100 * get_swap_gas_cost().into();
        
        //miss  grant of  necesasry allowances 

        let mut buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, false, true), 2, signer);

        buy_order.router_sign = sign(buy_order.order.get_poseidon_hash(), signer.into(), signer_pk);

        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, true, false), 0, zero_router());
        
        maker_orders.append(sell_order);

        let router_b = akira.balance_of_router(router, eth);

        start_prank(akira.contract_address, get_fee_recipient_exchange());
        assert(!akira.apply_unsafe_trade(buy_order, maker_orders,  usdc_amount * eth_amount / buy_order.order.base_asset, 100), 'EXPECTS_FAIL');
        stop_prank(akira.contract_address);
        let charge = 2 * gas_fee * akira.get_punishment_factor_bips().into() / 10000;
        assert(router_b - akira.balance_of_router(router, eth) == charge, 'WRONG_RECEIVED');
    }  
}

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

    fn get_eth_addr() -> ContractAddress {0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7.try_into().unwrap()}
        
    fn tfer_eth_funds_to(reciever: ContractAddress, amount: u256) {
        let caller_who_have_funds: ContractAddress = 0x00121108c052bbd5b273223043ad58a7e51c55ef454f3e02b0a0b4c559a925d4.try_into().unwrap();
        let ETH = IERC20Dispatcher { contract_address: get_eth_addr() };
        start_prank(ETH.contract_address, caller_who_have_funds);
        ETH.transfer(reciever, amount);
        stop_prank(ETH.contract_address);
    }

    fn get_fee_recipient_exchange()->ContractAddress {0x666.try_into().unwrap()}

    fn get_slow_mode()->SlowModeDelay { SlowModeDelay {block:5,ts:5*60}}  //5 blocks and 300seconds

    fn get_withdraw_action_cost()->u32 {100} 

    fn spawn_exchange() -> ContractAddress {
        let cls = declare('LayerAkira');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(get_fee_recipient_exchange().into());
        constructor.append(get_eth_addr().into());
        
        let mut serialized_slow_mode: Array<felt252> = ArrayTrait::new();
        Serde::serialize(@get_slow_mode(), ref serialized_slow_mode);
        loop {
            match serialized_slow_mode.pop_front() {
                Option::Some(felt) => { constructor.append(felt);},
                Option::None(_) => {break();}
            }
        };
        constructor.append(get_withdraw_action_cost().into());

        constructor.append(get_fee_recipient_exchange().into());
        let deployed = cls.deploy(@constructor).unwrap();
        return deployed;
    }

    fn get_trader_address_1()->ContractAddress {
        return 0x01d8e01188c4c8984fb19f00156491787e64fd2de1c3ce4eb9571924c540cf3b.try_into().unwrap();
    }

    fn deposit(trader:ContractAddress, amount:u256, token:ContractAddress, akira:ILayerAkiraDispatcher) {
        
        let erc = IERC20Dispatcher{contract_address: token};
        let (prev_total_supply,prev_user_balance) = (akira.total_supply(token), akira.balanceOf(trader, token));
        start_prank(token, trader);erc.approve(akira.contract_address,amount);stop_prank(token);
        start_prank(akira.contract_address, trader); akira.deposit(trader, token, amount); stop_prank(akira.contract_address);
        assert(akira.total_supply(token) == prev_total_supply + amount,'WRONG_MINT');
        assert(akira.balanceOf(trader, token) == prev_user_balance + amount,'WRONG_MINT'); 
    }

    fn prepare_double_gas_fee_native(akira:ILayerAkiraDispatcher, gas_action:u32)-> GasFee {
        let latest_gas_price = akira.get_latest_gas_price();
        let gas_deduct = latest_gas_price * 2 * gas_action.into();
        akira.get_wrapped_native_token().print();
        GasFee{ gas_per_action:get_withdraw_action_cost(), fee_token:get_eth_addr(), 
                max_gas_price: latest_gas_price * 2, conversion_rate: (1,1),
        }
    }



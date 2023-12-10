
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
    use snforge_std::signature::{ StarkCurveKeyPair, StarkCurveKeyPairTrait, Signer, Verifier };
    fn get_eth_addr() -> ContractAddress {0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7.try_into().unwrap()}

    fn get_usdc_addr() ->ContractAddress {0x05a643907b9a4bc6a55e9069c4fd5fd1f5c79a22470690f75556c4736e34426.try_into().unwrap()}
        
    fn tfer_eth_funds_to(reciever: ContractAddress, amount: u256) {
        let caller_who_have_funds: ContractAddress = 0x00121108c052bbd5b273223043ad58a7e51c55ef454f3e02b0a0b4c559a925d4.try_into().unwrap();
        let ETH = IERC20Dispatcher { contract_address: get_eth_addr() };
        start_prank(ETH.contract_address, caller_who_have_funds);
        ETH.transfer(reciever, amount);
        stop_prank(ETH.contract_address);
    }
    fn tfer_usdc_funds_to(reciever: ContractAddress, amount: u256) {
        let caller_who_have_funds: ContractAddress = 0x0711c27004518b375e5c3521223a87704d4b72367d353d797665aa0d1edc5f52.try_into().unwrap();
        let USDC = IERC20Dispatcher { contract_address: get_usdc_addr() };
        start_prank(USDC.contract_address, caller_who_have_funds);
        USDC.transfer(reciever, amount);
        stop_prank(USDC.contract_address);
    }


    fn get_fee_recipient_exchange()->ContractAddress {0x666.try_into().unwrap()}

    fn get_slow_mode()->SlowModeDelay { SlowModeDelay {block:5,ts:5*60}}  //5 blocks and 300seconds

    fn get_withdraw_action_cost()->u32 {100} 

    fn spawn_exchange() -> ContractAddress {
        let cls = declare('LayerAkira');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(get_eth_addr().into());
        constructor.append(get_fee_recipient_exchange().into());
        
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
        return 0x0541cf2823e5d004E9a5278ef8B691B97382FD0c9a6B833a56131E12232A7F0F.try_into().unwrap();
        // return 0x01d8e01188c4c8984fb19f00156491787e64fd2de1c3ce4eb9571924c540cf3b.try_into().unwrap();
    }
    fn get_trader_address_2() -> ContractAddress {
        return 0x024e8044680FEcDe3f23d4E270c7b0fA23c487Ae7B31b812ff72aFa7Bc7f6116.try_into().unwrap();
    }

    fn get_trader_signer_and_pk_1()->(felt252,felt252){
        return (0x6599a0c34699a5c48ae6ff359decc0618ce982be00654f2b12945cae5bb6788,
                                0x0455e57d60556bf07b184308bc6708caa5b64c7b41178a06092bb8a58057d33b);
    }

    fn get_trader_signer_and_pk_2()->(felt252, felt252) {
        return (0x61c5ec8851e6e8fcdcc065b6724f75bdf4055857dacf3b6be1ac9f1b3dc6fb2,
                                0x0295697db67cfcd0e0a04a26ab2e1333ebc6266d9c5c91be8926922ae0f445c4);
    }

    fn deposit(trader:ContractAddress, amount:u256, token:ContractAddress, akira:ILayerAkiraDispatcher) {
        
        let erc = IERC20Dispatcher{contract_address: token};
        let (prev_total_supply,prev_user_balance) = (akira.total_supply(token), akira.balanceOf(trader, token));
        start_prank(token, trader);erc.approve(akira.contract_address, amount);stop_prank(token);
        start_prank(akira.contract_address, trader); akira.deposit(trader, token, amount); stop_prank(akira.contract_address);
        assert(akira.total_supply(token) == prev_total_supply + amount,'WRONG_MINT');
        assert(akira.balanceOf(trader, token) == prev_user_balance + amount,'WRONG_MINT'); 
    }

    fn prepare_double_gas_fee_native(akira:ILayerAkiraDispatcher, gas_action:u32)-> GasFee {
        let latest_gas_price = akira.get_latest_gas_price();
        let gas_deduct = latest_gas_price * 2 * gas_action.into();
        GasFee{ gas_per_action:get_withdraw_action_cost(), fee_token:get_eth_addr(), 
                max_gas_price: latest_gas_price * 2, conversion_rate: (1,1),
        }
    }

    fn sign(message_hash:felt252,pub:felt252,priv:felt252)->(felt252, felt252) {
        let mut signer = StarkCurveKeyPair{public_key:pub, private_key:priv};
        return signer.sign(message_hash).unwrap();
    }



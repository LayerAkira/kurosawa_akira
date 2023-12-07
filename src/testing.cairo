
#[cfg(test)]
mod tests {
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_prank,start_warp,stop_warp,stop_prank,declare,ContractClassTrait};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::LayerAkira::LayerAkira;

    use kurosawa_akira::ILayerAkira::{ILayerAkiraDispatcher, ILayerAkiraDispatcherTrait};



    // fn get_in_base(rate:@Rate,qty:u256) -> u256 {
    //     let r:Rate = *rate;
    //     return qty *  (r.quote) / (r.base);
    // }


// qty = 1eth
// price = 1800usd 
// 

    fn deposit(account_who_deposits:ContractAddress,amount:ContractAddress) {
    }

    fn print_u(res: u256) {
        let a: felt252 = res.try_into().unwrap();
        let mut output: Array<felt252> = ArrayTrait::new();
        output.append(a);
        debug::print(output);
    }


    fn spawn_exchange() -> ContractAddress {
        let cls = declare('LayerAkira');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        // constructor.append(pub_key);
        let deployed = cls.deploy(@constructor).unwrap();
        return deployed;
    }

    fn get_sub_s(acc: ContractAddress) -> ContractAddress {
        let cls = declare('SimpleSubsribeServiceContract');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(acc.into());
        let deployed = cls.deploy(@constructor).unwrap();
        return deployed;
    }

    fn get_sub_s_02() -> ContractAddress {
        let cls = declare('SimpleSubsribeServiceContract02');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        let deployed = cls.deploy(@constructor).unwrap();
        return deployed;
    }

    #[test]
    // #[ignore]
    //#[available_gas(10000000000)]
    #[fork("latest")]
    fn test_deposit() {
        let akira_contract_addr = spawn_exchange();
        let d:ContractAddress = 1.try_into().unwrap();
        let akira = ILayerAkiraDispatcher{contract_address:akira_contract_addr};
        
        // let r = Rate {base:1000000000000000000,quote:1200000000};

        akira.set_fee_recipient(d);
        akira.get_fee_recipient().print();

        // LayerAkiraDispat

      
    }

  
}
